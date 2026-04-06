from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.repositories.tables import food_match_history


class HistoryRepository:
    # Summary: Initializes a match-history repository bound to an active SQLAlchemy session.
    # Parameters:
    # - session (AsyncSession): SQLAlchemy async session used for all repository operations.
    # Returns:
    # - None: Stores the session for subsequent method calls.
    # Raises/Throws:
    # - None: Initialization only stores references and performs no I/O.
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    # Summary: Searches historical phrase-to-food matches for a user.
    # Parameters:
    # - user_key (str): User identifier whose history rows are queried.
    # - query (str): Case-insensitive phrase fragment used for ILIKE matching.
    # Returns:
    # - list[dict[str, Any]]: Ranked historical match rows sorted by confidence and recency.
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    async def search_matches(self, user_key: str, query: str) -> list[dict[str, Any]]:
        stmt = (
            select(
                food_match_history.c.raw_phrase,
                food_match_history.c.quantity_text,
                food_match_history.c.usda_fdc_id,
                food_match_history.c.usda_description,
                food_match_history.c.times_confirmed,
                food_match_history.c.last_confirmed_at,
            )
            .where(food_match_history.c.user_key == user_key)
            .where(food_match_history.c.raw_phrase.ilike(f"%{query}%"))
            .order_by(food_match_history.c.times_confirmed.desc(), food_match_history.c.last_confirmed_at.desc())
            .limit(10)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    # Summary: Inserts or updates a confirmed phrase-to-food mapping and increments confirmation count.
    # Parameters:
    # - user_key (str): User identifier owning the match-history row.
    # - raw_phrase (str): Original food phrase captured from user input.
    # - quantity_text (str | None): Optional quantity text paired with the phrase.
    # - usda_fdc_id (int): USDA FDC identifier mapped to the phrase.
    # - usda_description (str): USDA description mapped to the phrase.
    # - confirmed_at (DateTimeValue): Timestamp used for last-confirmed bookkeeping.
    # - updated_at (DateTimeValue): Timestamp used for update bookkeeping.
    # Returns:
    # - dict[str, Any]: Persisted history row after insert/upsert resolution.
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    async def record_confirmed_match(
        self,
        user_key: str,
        raw_phrase: str,
        quantity_text: str | None,
        usda_fdc_id: int,
        usda_description: str,
        confirmed_at: DateTimeValue,
        updated_at: DateTimeValue,
    ) -> dict[str, Any]:
        stmt = pg_insert(food_match_history).values(
            user_key=user_key,
            raw_phrase=raw_phrase,
            quantity_text=quantity_text,
            usda_fdc_id=usda_fdc_id,
            usda_description=usda_description,
            times_confirmed=1,
            last_confirmed_at=confirmed_at,
            updated_at=updated_at,
        )

        stmt = (
            stmt.on_conflict_do_update(
                constraint="idx_food_match_history_match_key",
                set_={
                    "times_confirmed": food_match_history.c.times_confirmed + 1,
                    "last_confirmed_at": stmt.excluded.last_confirmed_at,
                    "updated_at": stmt.excluded.updated_at,
                },
            )
            .returning(*food_match_history.c)
        )

        result = await self._session.execute(stmt)
        row = result.mappings().one()
        return dict(row)
