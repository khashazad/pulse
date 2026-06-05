"""Daily-target-profile persistence layer.

Provides :class:`TargetsRepository`, which owns every SQL statement against
the ``daily_target_profile`` table: per-user fetch and idempotent upsert of
macro/weight targets.

Sits between the targets service and the underlying Postgres table definition
(``repositories/tables.py``); it is the only module in the codebase allowed to
issue ``daily_target_profile`` SQL.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.repositories.tables import daily_target_profile


class TargetsRepository:
    def __init__(self, session: AsyncSession) -> None:
        """Bind the repository to an open async session.

        **Inputs:**
        - session (AsyncSession): SQLAlchemy async session used for all queries
          issued by this repository instance.
        """
        self._session = session

    async def get_target_profile(self, user_key: str) -> dict[str, Any] | None:
        """Fetch the active macro target profile for a user.

        **Inputs:**
        - user_key (str): User identifier whose target profile is queried.

        **Outputs:**
        - dict[str, Any] | None: Target-profile row mapping when found,
          otherwise ``None``.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        stmt = (
            select(*daily_target_profile.c)
            .where(daily_target_profile.c.user_key == user_key)
            .limit(1)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        if row is None:
            return None
        return dict(row)

    async def upsert_targets(
        self,
        user_key: str,
        calories: int,
        protein_g: float,
        carbs_g: float,
        fat_g: float,
        target_weight_lb: float | None = None,
        *,
        updated_at: DateTimeValue,
    ) -> None:
        """Insert or update the user's macro target profile.

        Uses Postgres ``ON CONFLICT`` against the per-user unique index so the
        call is idempotent.

        **Inputs:**
        - user_key (str): User identifier owning the profile.
        - calories (int): Target calories.
        - protein_g (float): Target protein grams.
        - carbs_g (float): Target carbohydrate grams.
        - fat_g (float): Target fat grams.
        - target_weight_lb (float | None): Optional target body weight in pounds.
        - updated_at (DateTimeValue): Timestamp for last-update bookkeeping.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        stmt = pg_insert(daily_target_profile).values(
            user_key=user_key,
            calories_target=calories,
            protein_g_target=protein_g,
            carbs_g_target=carbs_g,
            fat_g_target=fat_g,
            target_weight_lb=target_weight_lb,
            updated_at=updated_at,
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=[daily_target_profile.c.user_key],
            set_={
                "calories_target": stmt.excluded.calories_target,
                "protein_g_target": stmt.excluded.protein_g_target,
                "carbs_g_target": stmt.excluded.carbs_g_target,
                "fat_g_target": stmt.excluded.fat_g_target,
                "target_weight_lb": stmt.excluded.target_weight_lb,
                "updated_at": updated_at,
            },
        )
        await self._session.execute(stmt)
