"""Idempotent upserts for activity rows. Each function returns
``(inserted, updated)``; insert-vs-update is detected per row with the
Postgres ``xmax = 0`` trick in a RETURNING clause."""

from __future__ import annotations

from sqlalchemy import Table, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.activity import ids
from pulse_server.activity.models import (
    AppleWorkout,
    DailyActivity,
    StrengthSet,
    StrengthWorkout,
)
from pulse_server.repositories.tables import (
    apple_workouts,
    daily_activity,
    strength_sets,
    strength_workouts,
)

_INSERTED_FLAG = text("(xmax = 0) AS inserted")


async def _upsert_row(
    session: AsyncSession, table: Table, values: dict, conflict_cols: list[str]
) -> bool:
    """Upsert one row and report whether it was freshly inserted.

    **Inputs:**
    - session (AsyncSession): Active session (caller owns the commit).
    - table: Target SQLAlchemy Core table.
    - values (dict): Column→value mapping for the row.
    - conflict_cols (list[str]): Columns forming the conflict target.

    **Outputs:**
    - bool: True if inserted, False if an existing row was updated.
    """
    insert_stmt = pg_insert(table).values(**values)
    update_cols = {c: insert_stmt.excluded[c] for c in values if c not in conflict_cols}
    returning_stmt = insert_stmt.on_conflict_do_update(
        index_elements=conflict_cols, set_=update_cols
    ).returning(_INSERTED_FLAG)
    result = await session.execute(returning_stmt)
    return bool(result.scalar_one())


def _tally(flags: list[bool]) -> tuple[int, int]:
    """Split insert flags into (inserted, updated) counts.

    **Inputs:**
    - flags (list[bool]): Per-row inserted flags.

    **Outputs:**
    - tuple[int, int]: (inserted_count, updated_count).
    """
    inserted = sum(1 for f in flags if f)
    return inserted, len(flags) - inserted


async def upsert_apple_workouts(
    session: AsyncSession, workouts: list[AppleWorkout]
) -> tuple[int, int]:
    """Upsert Apple workout sessions keyed on their deterministic id.

    **Inputs:**
    - session (AsyncSession): Active session (caller commits).
    - workouts (list[AppleWorkout]): Parsed sessions.

    **Outputs:**
    - tuple[int, int]: (inserted, updated).
    """
    flags: list[bool] = []
    for w in workouts:
        values = {
            "id": ids.apple_workout_id(w.user_key, w.start_time, w.activity_type),
            "user_key": w.user_key,
            "activity_type": w.activity_type,
            "source_name": w.source_name,
            "start_time": w.start_time,
            "end_time": w.end_time,
            "duration_min": w.duration_min,
            "active_energy_cal": w.active_energy_cal,
            "basal_energy_cal": w.basal_energy_cal,
            "avg_heart_rate": w.avg_heart_rate,
            "max_heart_rate": w.max_heart_rate,
            "distance_km": w.distance_km,
            "step_count": w.step_count,
            "flights_climbed": w.flights_climbed,
            "indoor": w.indoor,
            "elevation_ascended_m": w.elevation_ascended_m,
            "avg_mets": w.avg_mets,
            "temperature_f": w.temperature_f,
            "humidity_pct": w.humidity_pct,
            "timezone": w.timezone,
            "route_gpx_path": w.route_gpx_path,
        }
        flags.append(await _upsert_row(session, apple_workouts, values, ["id"]))
    return _tally(flags)


async def upsert_daily_activity(
    session: AsyncSession, days: list[DailyActivity]
) -> tuple[int, int]:
    """Upsert daily activity summaries keyed on (user_key, date).

    **Inputs:**
    - session (AsyncSession): Active session (caller commits).
    - days (list[DailyActivity]): Parsed daily summaries.

    **Outputs:**
    - tuple[int, int]: (inserted, updated).
    """
    flags: list[bool] = []
    for d in days:
        values = {
            "user_key": d.user_key,
            "date": d.date,
            "active_energy_cal": d.active_energy_cal,
            "active_energy_goal": d.active_energy_goal,
            "exercise_minutes": d.exercise_minutes,
            "exercise_goal": d.exercise_goal,
            "stand_hours": d.stand_hours,
            "stand_goal": d.stand_goal,
        }
        flags.append(await _upsert_row(session, daily_activity, values, ["user_key", "date"]))
    return _tally(flags)


async def upsert_strength(
    session: AsyncSession,
    workouts: list[StrengthWorkout],
    sets: list[StrengthSet],
) -> tuple[int, int]:
    """Upsert Hevy session headers and their sets keyed on deterministic ids.

    **Inputs:**
    - session (AsyncSession): Active session (caller commits).
    - workouts (list[StrengthWorkout]): Deduplicated session headers.
    - sets (list[StrengthSet]): Flat list of sets.

    **Outputs:**
    - tuple[int, int]: (inserted, updated) across both tables combined.
    """
    flags: list[bool] = []
    for w in workouts:
        values = {
            "id": ids.strength_workout_id(w.user_key, w.title, w.start_time),
            "user_key": w.user_key,
            "title": w.title,
            "start_time": w.start_time,
            "end_time": w.end_time,
            "description": w.description,
        }
        flags.append(await _upsert_row(session, strength_workouts, values, ["id"]))
    for s in sets:
        workout_id = ids.strength_workout_id(s.user_key, s.workout_title, s.workout_start_time)
        values = {
            "id": ids.strength_set_id(workout_id, s.exercise_title, s.set_index),
            "strength_workout_id": workout_id,
            "user_key": s.user_key,
            "exercise_title": s.exercise_title,
            "superset_id": s.superset_id,
            "exercise_notes": s.exercise_notes,
            "set_index": s.set_index,
            "set_type": s.set_type,
            "weight_lbs": s.weight_lbs,
            "reps": s.reps,
            "distance_km": s.distance_km,
            "duration_seconds": s.duration_seconds,
            "rpe": s.rpe,
        }
        flags.append(await _upsert_row(session, strength_sets, values, ["id"]))
    return _tally(flags)
