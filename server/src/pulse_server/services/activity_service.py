"""Activity read business logic: assemble feed pages, detail, and summaries
from ActivityReadRepository rows into the response DTOs."""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.models.activity import (
    ActivityDeltas,
    ActivityPeriod,
    ActivitySummary,
    ActivityTotals,
    ActivityWorkoutDetail,
    ActivityWorkoutSummary,
    MetricDelta,
    StrengthBrief,
    StrengthTotals,
    WorkoutExercise,
    WorkoutFeedPage,
    WorkoutSet,
)
from pulse_server.repositories.activity import ActivityReadRepository
from pulse_server.services.activity_summary import (
    bucket_volume,
    compute_top_lifts,
    est_one_rep_max,
    pct_change,
    period_bounds,
    previous_bounds,
    rollup_by_type,
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
    then delegates to the pure-math helpers in ``activity_summary`` to
    produce totals, deltas, by-type breakdown, volume series, and top lifts.

    **Inputs:**
    - session (AsyncSession): Active database session.
    - user_key (str): Owning user's scoping key.
    - period (ActivityPeriod): Granularity — ``"week"``, ``"month"``, or ``"year"``.
    - anchor (date): A date inside the target period (defaults applied by the router).
    - tz (str): IANA timezone name used to resolve workout dates into local
      calendar periods (passed through from the router).

    **Outputs:**
    - ActivitySummary: Assembled trend summary including totals, period-over-period
      deltas, by-type breakdown, volume series, and top lifts.
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
        by_type=rollup_by_type(cur, top_n=5),
        volume_series=bucket_volume(_build_vol_rows(history, start, end), period, start, end),
        top_lifts=compute_top_lifts(history, period_start=start),
    )
