from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.repositories.tables import daily_target_profile


class TargetsRepository:
    # Summary: Initializes a targets repository bound to an active SQLAlchemy session.
    # Parameters:
    # - session (AsyncSession): SQLAlchemy async session used for all repository operations.
    # Returns:
    # - None: Stores the session for subsequent method calls.
    # Raises/Throws:
    # - None: Initialization only stores references and performs no I/O.
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    # Summary: Fetches the active macro target profile for a user.
    # Parameters:
    # - user_key (str): User identifier whose target profile is queried.
    # Returns:
    # - dict[str, Any] | None: Target-profile row mapping when found, otherwise None.
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    async def get_target_profile(self, user_key: str) -> dict[str, Any] | None:
        stmt = select(*daily_target_profile.c).where(daily_target_profile.c.user_key == user_key).limit(1)
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        if row is None:
            return None
        return dict(row)

    # Summary: Inserts or updates the user's macro target profile.
    # Parameters:
    # - user_key (str): User identifier owning the profile.
    # - calories (int): Target calories.
    # - protein_g (float): Target protein grams.
    # - carbs_g (float): Target carbohydrate grams.
    # - fat_g (float): Target fat grams.
    # - updated_at (DateTimeValue): Timestamp for last-update bookkeeping.
    # Returns:
    # - None: Executes insert/upsert side effect only.
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    async def upsert_targets(
        self,
        user_key: str,
        calories: int,
        protein_g: float,
        carbs_g: float,
        fat_g: float,
        updated_at: DateTimeValue,
    ) -> None:
        stmt = pg_insert(daily_target_profile).values(
            user_key=user_key,
            calories_target=calories,
            protein_g_target=protein_g,
            carbs_g_target=carbs_g,
            fat_g_target=fat_g,
            updated_at=updated_at,
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=[daily_target_profile.c.user_key],
            set_={
                "calories_target": stmt.excluded.calories_target,
                "protein_g_target": stmt.excluded.protein_g_target,
                "carbs_g_target": stmt.excluded.carbs_g_target,
                "fat_g_target": stmt.excluded.fat_g_target,
                "updated_at": updated_at,
            },
        )
        await self._session.execute(stmt)
