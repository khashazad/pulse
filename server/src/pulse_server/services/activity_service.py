"""Activity read business logic: assemble feed pages, detail, summaries, and
activity-type settings from ActivityReadRepository rows into the response DTOs."""

from __future__ import annotations

import re
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.models.activity import (
    ActivityDeltas,
    ActivityPeriod,
    ActivitySummary,
    ActivityTotals,
    ActivityTypeSetting,
    ActivityTypesResponse,
    ActivityWorkoutDetail,
    ActivityWorkoutSummary,
    DayGroup,
    MetricDelta,
    StrengthBrief,
    StrengthTotals,
    WeekDetail,
    WorkoutExercise,
    WorkoutFeedPage,
    WorkoutSet,
)
from pulse_server.repositories.activity import ActivityReadRepository
from pulse_server.services.activity_cardio import effective_is_cardio
from pulse_server.services.activity_summary import (
    bucket_volume,
    compute_top_lifts,
    est_one_rep_max,
    months_in_year,
    pct_change,
    period_bounds,
    previous_bounds,
    rollup_by_type,
    weeks_in_month,
)

MAX_FEED_LIMIT = 100
DEFAULT_FEED_LIMIT = 50


def _set_volume(row: dict) -> float:
    """Volume contribution of one strength set: ``weight_lbs * reps``.

    **Inputs:**
    - row (dict): A set row with ``weight_lbs`` and ``reps`` keys.

    **Outputs:**
    - float: ``weight_lbs * reps``, or ``0.0`` when either value is missing/zero.
    """
    if row["weight_lbs"] and row["reps"]:
        return float(row["weight_lbs"]) * int(row["reps"])
    return 0.0


def _metric_delta(current: float, previous: float) -> MetricDelta:
    """Build a ``MetricDelta`` carrying the current/previous values and their percent change.

    **Inputs:**
    - current (float): Current-period value.
    - previous (float): Prior-period value.

    **Outputs:**
    - MetricDelta: The packaged delta, with ``pct`` from :func:`pct_change`.
    """
    return MetricDelta(current=current, previous=previous, pct=pct_change(current, previous))


async def list_workout_feed(
    session: AsyncSession,
    user_key: str,
    before: DateTimeValue | None,
    before_id: UUID | None,
    limit: int,
    activity_type: str | None,
) -> WorkoutFeedPage:
    """Build one page of the workout feed, enriching strength rows with briefs.

    **Inputs:**
    - session (AsyncSession): Active session.
    - user_key (str): Owning user's scoping key.
    - before (datetime | None): ``start_time`` component of the page cursor.
    - before_id (UUID | None): Id tiebreaker paired with ``before``.
    - limit (int): Page size (clamped to ``MAX_FEED_LIMIT``).
    - activity_type (str | None): Optional exact type filter.

    **Outputs:**
    - WorkoutFeedPage: Items newest-first plus the composite ``(next_before,
      next_before_id)`` cursor (both None when the page was not full).
    """
    limit = max(1, min(limit, MAX_FEED_LIMIT))
    repo = ActivityReadRepository(session)
    rows = await repo.list_workouts(user_key, before, before_id, limit, activity_type)
    linked_ids = [r["linked_strength_workout_id"] for r in rows if r["linked_strength_workout_id"]]
    briefs = await repo.strength_briefs(linked_ids) if linked_ids else {}
    items: list[ActivityWorkoutSummary] = []
    for r in rows:
        sw_id = r["linked_strength_workout_id"]
        brief = briefs.get(sw_id) if sw_id else None
        items.append(
            ActivityWorkoutSummary(
                id=r["id"],
                activity_type=r["activity_type"],
                start_time=r["start_time"],
                end_time=r["end_time"],
                duration_min=r["duration_min"],
                active_energy_cal=r["active_energy_cal"],
                distance_km=r["distance_km"],
                has_strength_detail=brief is not None,
                strength_brief=StrengthBrief(**brief) if brief else None,
            )
        )
    page_full = len(rows) == limit
    next_before = rows[-1]["start_time"] if page_full else None
    next_before_id = rows[-1]["id"] if page_full else None
    return WorkoutFeedPage(items=items, next_before=next_before, next_before_id=next_before_id)


def _build_exercises(set_rows: list[dict]) -> tuple[list[WorkoutExercise], StrengthTotals]:
    """Group ordered set rows into exercises with volume and top set; sum totals.

    **Inputs:**
    - set_rows (list[dict]): Set rows ordered by ``(exercise_title, set_index)``.

    **Outputs:**
    - tuple[list[WorkoutExercise], StrengthTotals]: Per-exercise blocks and the
      workout-level totals.
    """
    grouped: dict[str, list[dict]] = {}
    for r in set_rows:
        grouped.setdefault(r["exercise_title"], []).append(r)
    exercises: list[WorkoutExercise] = []
    total_volume = 0.0
    total_sets = 0
    for title, rows in grouped.items():
        sets = [
            WorkoutSet(
                set_index=r["set_index"],
                set_type=r["set_type"],
                weight_lbs=r["weight_lbs"],
                reps=r["reps"],
                rpe=r["rpe"],
                distance_km=r["distance_km"],
                duration_seconds=r["duration_seconds"],
            )
            for r in rows
        ]
        # Single pass: accumulate volume and track the highest-est-1RM set, then
        # reference the already-built ``sets`` element for ``top_set``.
        volume = 0.0
        top_index: int | None = None
        best_e1rm = -1.0
        for i, r in enumerate(rows):
            volume += _set_volume(r)
            if r["weight_lbs"] and r["reps"]:
                e1rm = est_one_rep_max(float(r["weight_lbs"]), int(r["reps"]))
                if e1rm > best_e1rm:
                    best_e1rm = e1rm
                    top_index = i
        top_set = sets[top_index] if top_index is not None else None
        exercises.append(
            WorkoutExercise(
                exercise_title=title,
                superset_id=rows[0]["superset_id"],
                set_count=len(rows),
                volume_lbs=volume,
                top_set=top_set,
                sets=sets,
            )
        )
        total_volume += volume
        total_sets += len(rows)
    totals = StrengthTotals(
        exercise_count=len(grouped),
        set_count=total_sets,
        volume_lbs=total_volume,
    )
    return exercises, totals


async def get_workout_detail(
    session: AsyncSession,
    user_key: str,
    workout_id: UUID,
) -> ActivityWorkoutDetail | None:
    """Assemble a workout's Apple stats plus linked Hevy exercises, if any.

    **Inputs:**
    - session (AsyncSession): Active session.
    - user_key (str): Owning user's scoping key.
    - workout_id (UUID): The ``apple_workouts.id`` to detail.

    **Outputs:**
    - ActivityWorkoutDetail | None: The detail, or None when the workout is absent.
    """
    repo = ActivityReadRepository(session)
    w = await repo.get_workout(user_key, workout_id)
    if w is None:
        return None
    exercises: list[WorkoutExercise] = []
    totals: StrengthTotals | None = None
    if w["linked_strength_workout_id"]:
        set_rows = await repo.sets_for_workout(w["linked_strength_workout_id"])
        if set_rows:
            exercises, totals = _build_exercises(set_rows)
    return ActivityWorkoutDetail(
        id=w["id"],
        activity_type=w["activity_type"],
        start_time=w["start_time"],
        end_time=w["end_time"],
        duration_min=w["duration_min"],
        active_energy_cal=w["active_energy_cal"],
        basal_energy_cal=w["basal_energy_cal"],
        avg_heart_rate=w["avg_heart_rate"],
        max_heart_rate=w["max_heart_rate"],
        distance_km=w["distance_km"],
        elevation_ascended_m=w["elevation_ascended_m"],
        step_count=w["step_count"],
        flights_climbed=w["flights_climbed"],
        avg_mets=w["avg_mets"],
        indoor=w["indoor"],
        exercises=exercises,
        strength_totals=totals,
    )


def _totals(rows: list[dict]) -> ActivityTotals:
    """Sum workout count, duration, and active energy over rows.

    **Inputs:**
    - rows (list[dict]): Workout rows with ``duration_min`` and ``active_energy_cal``.

    **Outputs:**
    - ActivityTotals: Aggregated headline totals for the given set of rows.
    """
    return ActivityTotals(
        workout_count=len(rows),
        total_duration_min=sum(float(r["duration_min"] or 0) for r in rows),
        total_active_energy_cal=sum(float(r["active_energy_cal"] or 0) for r in rows),
    )


def _build_vol_rows(history: list[dict], start: DateValue, end: DateValue) -> list[dict]:
    """Turn current-period strength sets into rows for :func:`bucket_volume`.

    Each in-period set yields one volume-only row (``duration_min=0``); each
    distinct ``workout_id`` additionally yields one duration-only row
    (``volume_lbs=0``). Splitting volume from duration this way prevents the
    workout's minutes from being multiplied by its set count when the buckets
    sum each field.

    **Inputs:**
    - history (list[dict]): Strength-set rows with ``date``, ``weight_lbs``,
      ``reps``, ``duration_min``, ``workout_id``.
    - start (date): Inclusive period start; sets before it are skipped.
    - end (date): Inclusive period end; sets after it are skipped.

    **Outputs:**
    - list[dict]: Rows with ``date``, ``volume_lbs``, ``duration_min`` keys.
    """
    vol_rows: list[dict] = []
    seen_workout_ids: set = set()
    for h in history:
        if not (start <= h["date"] <= end):
            continue
        vol_rows.append({"date": h["date"], "volume_lbs": _set_volume(h), "duration_min": 0.0})
        wid = h["workout_id"]
        if wid not in seen_workout_ids:
            seen_workout_ids.add(wid)
            vol_rows.append(
                {
                    "date": h["date"],
                    "volume_lbs": 0.0,
                    "duration_min": float(h["duration_min"] or 0),
                }
            )
    return vol_rows


async def build_summary(
    session: AsyncSession,
    user_key: str,
    period: ActivityPeriod,
    anchor: DateValue,
    tz: str,
) -> ActivitySummary:
    """Assemble the week/month/year trend summary for a period.

    Fetches current and previous period workouts plus full strength history,
    then delegates to the pure-math helpers in ``activity_summary`` to produce
    totals, deltas, by-type breakdown, period-level week/month rollups, volume
    series, and top lifts.

    Both strength activity types are collapsed into a single ``"Weights"``
    label in ``by_type``.  ``weeks`` is populated only when ``period=="month"``
    (one entry per ISO week clamped to the month); ``months`` is populated only
    when ``period=="year"`` (always 12 entries).

    **Inputs:**
    - session (AsyncSession): Active database session.
    - user_key (str): Owning user's scoping key.
    - period (ActivityPeriod): Granularity — ``"week"``, ``"month"``, or ``"year"``.
    - anchor (date): A date inside the target period (defaults applied by the router).
    - tz (str): IANA timezone name used to resolve workout dates into local
      calendar periods (passed through from the router).

    **Outputs:**
    - ActivitySummary: Assembled trend summary including totals, period-over-period
      deltas, by-type breakdown, week/month rollups, volume series, and top lifts.
    """
    start, end = period_bounds(period, anchor)
    p_start, p_end = previous_bounds(period, anchor)
    repo = ActivityReadRepository(session)
    cur = await repo.workouts_in_range(user_key, start, end, tz=tz)
    prev = await repo.workouts_in_range(user_key, p_start, p_end, tz=tz)
    history = await repo.strength_history(user_key, end, tz=tz)
    cur_t, prev_t = _totals(cur), _totals(prev)
    deltas = ActivityDeltas(
        workout_count=_metric_delta(cur_t.workout_count, prev_t.workout_count),
        total_duration_min=_metric_delta(cur_t.total_duration_min, prev_t.total_duration_min),
        total_active_energy_cal=_metric_delta(
            cur_t.total_active_energy_cal, prev_t.total_active_energy_cal
        ),
    )
    return ActivitySummary(
        period=period,
        period_start=start,
        period_end=end,
        totals=cur_t,
        deltas=deltas,
        by_type=rollup_by_type(cur),
        weeks=weeks_in_month(cur, start, end) if period == "month" else [],
        months=months_in_year(cur, anchor.year) if period == "year" else [],
        volume_series=bucket_volume(_build_vol_rows(history, start, end), period, start, end),
        top_lifts=compute_top_lifts(history, period_start=start),
    )


async def get_week_detail(
    session: AsyncSession,
    user_key: str,
    anchor: DateValue,
    tz: str,
) -> WeekDetail:
    """Build the day-grouped workout view for the Mon-Sun week containing ``anchor``.

    Fetches workouts in range via ``workouts_in_range``, enriches any strength
    rows with ``strength_briefs``, then groups workouts by their ``local_date``
    into :class:`DayGroup` objects.  Only days that have at least one workout
    appear in the result.  Days are ordered newest-first; workouts within a day
    are also ordered newest-first by ``start_time``.

    **Inputs:**
    - session (AsyncSession): Active database session.
    - user_key (str): Owning user's scoping key.
    - anchor (date): Any date inside the target week; ``period_bounds("week", anchor)``
      derives the Mon-Sun bounds.
    - tz (str): IANA timezone name passed through to ``workouts_in_range`` for
      correct UTC-to-local date bucketing.

    **Outputs:**
    - WeekDetail: Assembled week detail with ``week_start``, ``week_end``, and
      the ``day_groups`` list (empty when the week has no workouts).
    """
    start, end = period_bounds("week", anchor)
    repo = ActivityReadRepository(session)
    rows = await repo.workouts_in_range(user_key, start, end, tz=tz)

    linked_ids = [r["linked_strength_workout_id"] for r in rows if r["linked_strength_workout_id"]]
    briefs = await repo.strength_briefs(linked_ids) if linked_ids else {}

    by_date: dict[DateValue, list[ActivityWorkoutSummary]] = {}
    for r in rows:
        sw_id = r["linked_strength_workout_id"]
        brief = briefs.get(sw_id) if sw_id else None
        summary = ActivityWorkoutSummary(
            id=r["id"],
            activity_type=r["activity_type"],
            start_time=r["start_time"],
            end_time=r["end_time"],
            duration_min=r["duration_min"],
            active_energy_cal=r["active_energy_cal"],
            distance_km=r["distance_km"],
            has_strength_detail=brief is not None,
            strength_brief=StrengthBrief(**brief) if brief else None,
        )
        d: DateValue = r["local_date"]
        by_date.setdefault(d, []).append(summary)

    day_groups: list[DayGroup] = [
        DayGroup(
            date=d,
            workouts=sorted(ws, key=lambda w: w.start_time, reverse=True),
        )
        for d, ws in sorted(by_date.items(), reverse=True)
    ]

    return WeekDetail(week_start=start, week_end=end, day_groups=day_groups)


def _display_name(activity_type: str) -> str:
    """Derive a human-readable display label from a camelCase activity type string.

    Inserts a space before each uppercase letter that is preceded by a lowercase
    letter so that, e.g., ``"TraditionalStrengthTraining"`` becomes
    ``"Traditional Strength Training"``. Single-word types (e.g. ``"Running"``)
    are returned unchanged.

    Args:
        activity_type (str): The bare Apple Health activity type string
            (e.g. ``"TraditionalStrengthTraining"``).

    Returns:
        str: The space-separated display label (e.g.
            ``"Traditional Strength Training"``).

    Raises:
        None
    """
    return re.sub(r"(?<=[a-z])(?=[A-Z])", " ", activity_type)


async def list_activity_types(
    session: AsyncSession,
    user_key: str,
) -> ActivityTypesResponse:
    """Return all activity types the user has recorded, enriched with effective cardio flags.

    Fetches the distinct activity types and their workout counts from the
    repository, loads per-type cardio overrides, resolves each type's effective
    ``is_cardio`` flag via :func:`effective_is_cardio`, and returns the list
    sorted by count descending (the repository already returns it in that order).

    Args:
        session (AsyncSession): Active database session.
        user_key (str): Owning user's scoping key.

    Returns:
        ActivityTypesResponse: List of :class:`ActivityTypeSetting` items,
            each carrying the type string, a best-effort display name,
            the workout count, and the resolved cardio flag.

    Raises:
        sqlalchemy.exc.SQLAlchemyError: On any database execution failure.
    """
    repo = ActivityReadRepository(session)
    types = await repo.distinct_activity_types(user_key)
    overrides = await repo.cardio_overrides(user_key)
    settings: list[ActivityTypeSetting] = [
        ActivityTypeSetting(
            activity_type=t["activity_type"],
            display_name=_display_name(t["activity_type"]),
            count=t["count"],
            is_cardio=effective_is_cardio(t["activity_type"], overrides),
        )
        for t in types
    ]
    return ActivityTypesResponse(types=settings)


async def set_activity_type_cardio(
    session: AsyncSession,
    user_key: str,
    activity_type: str,
    is_cardio: bool,
) -> ActivityTypeSetting:
    """Set the cardio flag for one of the user's activity types and return the updated setting.

    Validates that the activity type exists (i.e. the user has at least one
    workout with that type) before writing the override. Raises HTTP 404 when
    the type is unknown so the router can propagate it without extra handling.

    Args:
        session (AsyncSession): Active database session.
        user_key (str): Owning user's scoping key.
        activity_type (str): The Apple Health activity type to update.
        is_cardio (bool): The new cardio flag value.

    Returns:
        ActivityTypeSetting: The updated setting reflecting the new ``is_cardio``
            value, the type's current workout count, and its display name.

    Raises:
        fastapi.HTTPException: HTTP 404 when the activity type has no recorded
            workouts for this user.
        sqlalchemy.exc.SQLAlchemyError: On any database execution failure.
    """
    repo = ActivityReadRepository(session)
    types = await repo.distinct_activity_types(user_key)
    type_counts = {t["activity_type"]: t["count"] for t in types}
    if activity_type not in type_counts:
        raise HTTPException(status_code=404, detail="activity type not found")
    await repo.set_cardio_override(user_key, activity_type, is_cardio)
    return ActivityTypeSetting(
        activity_type=activity_type,
        display_name=_display_name(activity_type),
        count=type_counts[activity_type],
        is_cardio=is_cardio,
    )
