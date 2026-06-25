"""Read-only SQL for the activity endpoints.

Owns every query that powers the feed, workout detail, and trend summaries
against ``apple_workouts`` / ``strength_workouts`` / ``strength_sets``.
SQLAlchemy Core, returns plain dict rows.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.repositories.tables import apple_workouts, strength_sets


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
        limit: int,
        activity_type: str | None,
    ) -> list[dict[str, Any]]:
        """Return workouts newest-first, optionally filtered by type, with a cursor.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - before (datetime | None): Exclusive upper bound on ``start_time`` (cursor).
        - limit (int): Max rows to return.
        - activity_type (str | None): Optional exact ``activity_type`` filter.

        **Outputs:**
        - list[dict[str, Any]]: Apple workout rows ordered by ``start_time`` desc.
        """
        stmt = select(*apple_workouts.c).where(apple_workouts.c.user_key == user_key)
        if activity_type is not None:
            stmt = stmt.where(apple_workouts.c.activity_type == activity_type)
        if before is not None:
            stmt = stmt.where(apple_workouts.c.start_time < before)
        stmt = stmt.order_by(apple_workouts.c.start_time.desc()).limit(limit)
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
