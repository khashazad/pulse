from __future__ import annotations

import uuid
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.repositories.tables import daily_logs, food_entries


class EntriesRepository:
    # Summary: Initializes an entries repository bound to an active SQLAlchemy session.
    # Parameters:
    # - session (AsyncSession): SQLAlchemy async session used for all repository operations.
    # Returns:
    # - None: Stores the session for subsequent method calls.
    # Raises/Throws:
    # - None: Initialization only stores references and performs no I/O.
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    # Summary: Derives a deterministic daily log UUID using user key and log date.
    # Parameters:
    # - user_key (str): Unique user identifier owning the nutrition log.
    # - log_date (DateValue): Date associated with the daily log identifier.
    # Returns:
    # - str: UUID5 string derived from user key and date.
    # Raises/Throws:
    # - None: UUID derivation is deterministic for valid inputs.
    @staticmethod
    def daily_log_id(user_key: str, log_date: DateValue) -> str:
        return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{user_key}:{log_date.isoformat()}"))

    # Summary: Inserts a daily log if it does not already exist for the user/date pair.
    # Parameters:
    # - daily_log_id (str): UUID string for the daily log primary key.
    # - user_key (str): User identifier owning the log.
    # - log_date (DateValue): Date represented by the daily log.
    # Returns:
    # - None: Executes insert/upsert side effect only.
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    async def ensure_daily_log(self, daily_log_id: str, user_key: str, log_date: DateValue) -> None:
        stmt = (
            pg_insert(daily_logs)
            .values(id=daily_log_id, user_key=user_key, log_date=log_date)
            .on_conflict_do_nothing(index_elements=[daily_logs.c.user_key, daily_logs.c.log_date])
        )
        await self._session.execute(stmt)

    # Summary: Creates a food-entry row and returns the inserted record.
    # Parameters:
    # - entry_id (uuid.UUID): UUID for the entry primary key.
    # - daily_log_id (str): UUID string for the owning daily log.
    # - user_key (str): User identifier owning the entry.
    # - entry_group_id (uuid.UUID): UUID for grouping related entries.
    # - display_name (str): User-facing label for the consumed item.
    # - quantity_text (str): Original quantity phrase supplied by the user.
    # - normalized_quantity_value (float | None): Parsed numeric quantity value when available.
    # - normalized_quantity_unit (str | None): Parsed quantity unit when available.
    # - usda_fdc_id (int): USDA FDC identifier for mapped food.
    # - usda_description (str): USDA description for mapped food.
    # - calories (int): Calories for this entry.
    # - protein_g (float): Protein grams for this entry.
    # - carbs_g (float): Carbohydrate grams for this entry.
    # - fat_g (float): Fat grams for this entry.
    # - consumed_at (DateTimeValue): Timestamp when food was consumed.
    # Returns:
    # - dict[str, Any]: Inserted food-entry row as a mapping.
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    async def create_food_entry(
        self,
        entry_id: uuid.UUID,
        daily_log_id: str,
        user_key: str,
        entry_group_id: uuid.UUID,
        display_name: str,
        quantity_text: str,
        normalized_quantity_value: float | None,
        normalized_quantity_unit: str | None,
        usda_fdc_id: int,
        usda_description: str,
        calories: int,
        protein_g: float,
        carbs_g: float,
        fat_g: float,
        consumed_at: DateTimeValue,
    ) -> dict[str, Any]:
        stmt = (
            pg_insert(food_entries)
            .values(
                id=entry_id,
                daily_log_id=daily_log_id,
                user_key=user_key,
                entry_group_id=entry_group_id,
                display_name=display_name,
                quantity_text=quantity_text,
                normalized_quantity_value=normalized_quantity_value,
                normalized_quantity_unit=normalized_quantity_unit,
                usda_fdc_id=usda_fdc_id,
                usda_description=usda_description,
                calories=calories,
                protein_g=protein_g,
                carbs_g=carbs_g,
                fat_g=fat_g,
                consumed_at=consumed_at,
            )
            .returning(*food_entries.c)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().one()
        return dict(row)

    # Summary: Lists entries for a specific daily log ordered by consumption timestamp.
    # Parameters:
    # - daily_log_id (str): UUID string of the daily log to query.
    # Returns:
    # - list[dict[str, Any]]: Ordered food-entry rows for the given daily log.
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    async def list_entries_by_daily_log_id(self, daily_log_id: str) -> list[dict[str, Any]]:
        stmt = (
            select(*food_entries.c)
            .where(food_entries.c.daily_log_id == daily_log_id)
            .order_by(food_entries.c.consumed_at)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    # Summary: Deletes a food entry by primary key and reports whether a row was removed.
    # Parameters:
    # - entry_id (str): UUID string of the food-entry row to delete.
    # Returns:
    # - bool: True when a row is deleted, otherwise False.
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    async def delete_entry(self, entry_id: str) -> bool:
        stmt = delete(food_entries).where(food_entries.c.id == entry_id).returning(food_entries.c.id)
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None
