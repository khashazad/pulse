"""Activity read business logic: assemble feed pages, detail, and summaries
from ActivityReadRepository rows into the response DTOs."""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.models.activity import (
    ActivityWorkoutDetail,
    ActivityWorkoutSummary,
    StrengthBrief,
    StrengthTotals,
    WorkoutExercise,
    WorkoutFeedPage,
    WorkoutSet,
)
from pulse_server.repositories.activity import ActivityReadRepository
from pulse_server.services.activity_summary import est_one_rep_max

MAX_FEED_LIMIT = 100
DEFAULT_FEED_LIMIT = 50


async def list_workout_feed(
    session: AsyncSession,
    user_key: str,
    before: DateTimeValue | None,
    limit: int,
    activity_type: str | None,
) -> WorkoutFeedPage:
    """Build one page of the workout feed, enriching strength rows with briefs.

    **Inputs:**
    - session (AsyncSession): Active session.
    - user_key (str): Owning user's scoping key.
    - before (datetime | None): Cursor; return workouts strictly older than this.
    - limit (int): Page size (clamped to ``MAX_FEED_LIMIT``).
    - activity_type (str | None): Optional exact type filter.

    **Outputs:**
    - WorkoutFeedPage: Items newest-first plus the ``next_before`` cursor (None when
      the page was not full).
    """
    limit = max(1, min(limit, MAX_FEED_LIMIT))
    repo = ActivityReadRepository(session)
    rows = await repo.list_workouts(user_key, before, limit, activity_type)
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
    next_before = rows[-1]["start_time"] if len(rows) == limit else None
    return WorkoutFeedPage(items=items, next_before=next_before)


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
        volume = sum(
            float(r["weight_lbs"]) * int(r["reps"]) for r in rows if r["weight_lbs"] and r["reps"]
        )
        weighted = [r for r in rows if r["weight_lbs"] and r["reps"]]
        top_row = (
            max(weighted, key=lambda r: est_one_rep_max(float(r["weight_lbs"]), int(r["reps"])))
            if weighted
            else None
        )
        top_set: WorkoutSet | None = None
        if top_row is not None:
            top_set = WorkoutSet(
                set_index=top_row["set_index"],
                set_type=top_row["set_type"],
                weight_lbs=top_row["weight_lbs"],
                reps=top_row["reps"],
                rpe=top_row["rpe"],
                distance_km=top_row["distance_km"],
                duration_seconds=top_row["duration_seconds"],
            )
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
