"""Read-only SQL for the activity endpoints.

Owns every query that powers the feed, workout detail, and trend summaries
against ``apple_workouts`` / ``strength_workouts`` / ``strength_sets``.
SQLAlchemy Core, returns plain dict rows.
"""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy import Date, and_, cast, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.models.activity import WEIGHTS_ACTIVITY_TYPES
from pulse_server.repositories.tables import apple_workouts, strength_sets, strength_workouts


class ActivityReadRepository:
    """Async read repository for Apple/Hevy activity data."""

    def __init__(self, session: AsyncSession) -> None:
        """Bind the repository to an open async session.

        **Inputs:**
        - session (AsyncSession): Session used for all queries.
        """
        self._session = session

    async def list_workouts(
        self,
        user_key: str,
        before: DateTimeValue | None,
        before_id: UUID | None,
        limit: int,
        activity_type: str | None,
        group: str | None = None,
    ) -> list[dict[str, Any]]:
        """Return workouts newest-first, optionally filtered by type or group, with a cursor.

        Orders by ``(start_time desc, id desc)`` so the ordering is total even when
        two workouts share an exact ``start_time``. The cursor is the composite
        ``(before, before_id)``: rows strictly older than ``before``, plus rows at
        exactly ``before`` whose id sorts before ``before_id``. Passing ``before``
        without ``before_id`` falls back to a plain ``start_time < before`` bound.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - before (datetime | None): ``start_time`` component of the cursor.
        - before_id (UUID | None): Id tiebreaker for rows sharing ``before``'s start_time.
        - limit (int): Max rows to return.
        - activity_type (str | None): Optional exact ``activity_type`` filter.
        - group (str | None): Optional ``"weights"``/``"cardio"`` filter over activity_type.

        **Outputs:**
        - list[dict[str, Any]]: Apple workout rows ordered by ``(start_time, id)`` desc.
        """
        stmt = select(*apple_workouts.c).where(apple_workouts.c.user_key == user_key)
        if activity_type is not None:
            stmt = stmt.where(apple_workouts.c.activity_type == activity_type)
        if group == "weights":
            stmt = stmt.where(apple_workouts.c.activity_type.in_(WEIGHTS_ACTIVITY_TYPES))
        elif group == "cardio":
            stmt = stmt.where(apple_workouts.c.activity_type.notin_(WEIGHTS_ACTIVITY_TYPES))
        if before is not None:
            if before_id is not None:
                stmt = stmt.where(
                    or_(
                        apple_workouts.c.start_time < before,
                        and_(
                            apple_workouts.c.start_time == before,
                            apple_workouts.c.id < before_id,
                        ),
                    )
                )
            else:
                stmt = stmt.where(apple_workouts.c.start_time < before)
        stmt = stmt.order_by(apple_workouts.c.start_time.desc(), apple_workouts.c.id.desc()).limit(
            limit
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings()]

    async def strength_briefs(self, strength_workout_ids: list[UUID]) -> dict[UUID, dict[str, Any]]:
        """Aggregate set/exercise counts and volume for the given strength workouts.

        **Inputs:**
        - strength_workout_ids (list[UUID]): Workout ids to roll up.

        **Outputs:**
        - dict[UUID, dict]: ``{id: {exercise_count, set_count, volume_lbs}}``; ids
          with no sets are absent from the mapping.
        """
        if not strength_workout_ids:
            return {}
        volume = func.coalesce(func.sum(strength_sets.c.weight_lbs * strength_sets.c.reps), 0)
        stmt = (
            select(
                strength_sets.c.strength_workout_id.label("wid"),
                func.count(func.distinct(strength_sets.c.exercise_title)).label("exercise_count"),
                func.count().label("set_count"),
                volume.label("volume_lbs"),
            )
            .where(strength_sets.c.strength_workout_id.in_(strength_workout_ids))
            .group_by(strength_sets.c.strength_workout_id)
        )
        result = await self._session.execute(stmt)
        out: dict[UUID, dict[str, Any]] = {}
        for row in result.mappings():
            out[row["wid"]] = {
                "exercise_count": int(row["exercise_count"]),
                "set_count": int(row["set_count"]),
                "volume_lbs": float(row["volume_lbs"]),
            }
        return out

    async def get_workout(self, user_key: str, workout_id: UUID) -> dict[str, Any] | None:
        """Fetch a single Apple workout row by id, scoped to the user.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - workout_id (UUID): The ``apple_workouts.id`` to fetch.

        **Outputs:**
        - dict[str, Any] | None: The row as a plain dict, or None when absent.
        """
        stmt = (
            select(*apple_workouts.c)
            .where(apple_workouts.c.user_key == user_key)
            .where(apple_workouts.c.id == workout_id)
            .limit(1)
        )
        row = (await self._session.execute(stmt)).mappings().first()
        return dict(row) if row else None

    async def sets_for_workout(self, strength_workout_id: UUID) -> list[dict[str, Any]]:
        """Return all sets for a strength workout ordered by exercise then set index.

        **Inputs:**
        - strength_workout_id (UUID): The ``strength_workouts.id`` whose sets to fetch.

        **Outputs:**
        - list[dict[str, Any]]: Set rows ordered by ``(exercise_title, set_index)``.
        """
        stmt = (
            select(*strength_sets.c)
            .where(strength_sets.c.strength_workout_id == strength_workout_id)
            .order_by(strength_sets.c.exercise_title.asc(), strength_sets.c.set_index.asc())
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings()]

    async def workouts_in_range(
        self,
        user_key: str,
        start: DateValue,
        end: DateValue,
        tz: str,
    ) -> list[dict[str, Any]]:
        """Return workouts whose local-timezone start date falls within [start, end] inclusive.

        The ``start_time`` column is ``timestamptz``.  Converting it to a local date
        with a bare ``cast(..., Date)`` would resolve in whatever timezone the DB
        session uses (typically UTC), bucketing evening workouts into the wrong day.
        ``func.timezone(tz, start_time)`` converts to the wall-clock timestamp in
        ``tz`` first, so the date boundary matches the user's local calendar.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - start (date): Inclusive lower date bound (in the ``tz`` timezone).
        - end (date): Inclusive upper date bound (in the ``tz`` timezone).
        - tz (str): IANA timezone name (e.g. ``"America/Toronto"``) used for the
          UTC-to-local conversion before the date comparison.

        **Outputs:**
        - list[dict[str, Any]]: Rows with ``activity_type``, ``duration_min``,
          ``active_energy_cal``, and ``start_time``, ordered by ``start_time`` asc.

        **Raises:**
        - SQLAlchemyError: On any database execution failure.
        """
        col = cast(func.timezone(tz, apple_workouts.c.start_time), Date)
        stmt = (
            select(
                apple_workouts.c.activity_type,
                apple_workouts.c.duration_min,
                apple_workouts.c.active_energy_cal,
                apple_workouts.c.start_time,
            )
            .where(apple_workouts.c.user_key == user_key)
            .where(col >= start)
            .where(col <= end)
            .order_by(apple_workouts.c.start_time.asc())
        )
        result = await self._session.execute(stmt)
        return [dict(r) for r in result.mappings()]

    async def strength_history(
        self,
        user_key: str,
        end: DateValue,
        tz: str,
    ) -> list[dict[str, Any]]:
        """Return all strength sets up to ``end`` joined with their workout local-timezone date.

        The ``start_time`` column is ``timestamptz``.  ``func.timezone(tz, start_time)``
        converts it to the wall-clock timestamp in ``tz`` before casting to ``Date``,
        so the returned ``date`` field and the ``<= end`` filter both reflect the user's
        local calendar rather than UTC.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - end (date): Inclusive upper bound on the workout's local-timezone start date.
        - tz (str): IANA timezone name (e.g. ``"America/Toronto"``) used for the
          UTC-to-local conversion before the date comparison and label.

        **Outputs:**
        - list[dict[str, Any]]: Rows with ``exercise_title``, ``weight_lbs``, ``reps``,
          ``date`` (the workout's local-timezone start date), ``duration_min`` (derived
          from workout start/end), and ``workout_id``; ordered by workout ``start_time``
          asc then ``set_index`` asc.

        **Raises:**
        - SQLAlchemyError: On any database execution failure.
        """
        wdate = cast(func.timezone(tz, strength_workouts.c.start_time), Date)
        duration_min = (
            func.extract("epoch", strength_workouts.c.end_time - strength_workouts.c.start_time)
            / 60
        )
        stmt = (
            select(
                strength_sets.c.exercise_title,
                strength_sets.c.weight_lbs,
                strength_sets.c.reps,
                wdate.label("date"),
                duration_min.label("duration_min"),
                strength_workouts.c.id.label("workout_id"),
            )
            .select_from(
                strength_sets.join(
                    strength_workouts,
                    strength_sets.c.strength_workout_id == strength_workouts.c.id,
                )
            )
            .where(strength_sets.c.user_key == user_key)
            .where(wdate <= end)
            .order_by(strength_workouts.c.start_time.asc(), strength_sets.c.set_index.asc())
        )
        result = await self._session.execute(stmt)
        return [dict(r) for r in result.mappings()]
