"""Idempotent upserts for activity rows. Each function returns
``(inserted, updated)``; insert-vs-update is detected per row with the
Postgres ``xmax = 0`` trick in a RETURNING clause."""

from __future__ import annotations

from sqlalchemy import Table, bindparam, select, text, update
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
    - table (Table): Target SQLAlchemy Core table.
    - values (dict): Column→value mapping for the row.
    - conflict_cols (list[str]): Columns forming the conflict target.

    **Outputs:**
    - bool: True if inserted, False if an existing row was updated.

    **Raises/Throws:**
    - sqlalchemy.exc.SQLAlchemyError: If the statement fails to execute.
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
    inserted = sum(flags)
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

    **Raises/Throws:**
    - sqlalchemy.exc.SQLAlchemyError: If a statement fails to execute.
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

    **Raises/Throws:**
    - sqlalchemy.exc.SQLAlchemyError: If a statement fails to execute.
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

    **Raises/Throws:**
    - sqlalchemy.exc.SQLAlchemyError: If a statement fails to execute.
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
        values = {
            "id": ids.strength_set_id(s.strength_workout_id, s.exercise_title, s.set_index),
            "strength_workout_id": s.strength_workout_id,
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


_LINK_TYPES = ("TraditionalStrengthTraining", "Other")
_LINK_WINDOW_SECONDS = 1200  # ±20 minutes


async def link_apple_to_strength(session: AsyncSession, user_key: str) -> int:
    """Link each Hevy strength workout to its nearest in-window Apple workout, 1:1.

    Clears all existing links for ``user_key`` first, then greedily pairs every
    ``strength_workouts`` row to the nearest unclaimed ``apple_workouts`` row of
    type ``TraditionalStrengthTraining``/``Other`` whose ``start_time`` is within
    ±20 minutes, smallest offset winning. Idempotent.

    **Inputs:**
    - session (AsyncSession): Active session (caller owns the commit).
    - user_key (str): Scoping key whose rows are (re)linked.

    **Outputs:**
    - int: Number of Apple rows assigned a link.

    **Raises/Throws:**
    - sqlalchemy.exc.SQLAlchemyError: If a statement fails to execute.
    """
    await session.execute(
        update(apple_workouts)
        .where(apple_workouts.c.user_key == user_key)
        .values(linked_strength_workout_id=None)
    )
    strengths = (
        await session.execute(
            select(strength_workouts.c.id, strength_workouts.c.start_time)
            .where(strength_workouts.c.user_key == user_key)
            .order_by(strength_workouts.c.start_time.asc())
        )
    ).all()
    apples = (
        await session.execute(
            select(apple_workouts.c.id, apple_workouts.c.start_time)
            .where(apple_workouts.c.user_key == user_key)
            .where(apple_workouts.c.activity_type.in_(_LINK_TYPES))
            .order_by(apple_workouts.c.start_time.asc())
        )
    ).all()

    # Build all in-window candidate pairs, then greedily assign by smallest offset.
    candidates: list[tuple[float, object, object]] = []
    for s_id, s_start in strengths:
        for a_id, a_start in apples:
            offset = abs((a_start - s_start).total_seconds())
            if offset <= _LINK_WINDOW_SECONDS:
                candidates.append((offset, s_id, a_id))
    candidates.sort(key=lambda c: c[0])

    used_apple: set[object] = set()
    used_strength: set[object] = set()
    assignments: list[tuple[object, object]] = []  # (apple_id, strength_id)
    for _offset, s_id, a_id in candidates:
        if a_id in used_apple or s_id in used_strength:
            continue
        used_apple.add(a_id)
        used_strength.add(s_id)
        assignments.append((a_id, s_id))

    if assignments:
        await session.execute(
            update(apple_workouts)
            .where(apple_workouts.c.id == bindparam("a_id"))
            .values(linked_strength_workout_id=bindparam("s_id")),
            [{"a_id": a_id, "s_id": s_id} for a_id, s_id in assignments],
        )
    return len(assignments)
