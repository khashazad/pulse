"""Food-entry persistence layer.

Provides :class:`EntriesRepository`, which owns SQL access to ``food_entries``
plus the ``daily_logs`` parent row required to anchor each entry. Responsible
for: deterministic daily-log ID derivation, idempotent daily-log creation,
food-entry insert/list/delete, and projection of the public response columns.

Sits between the food-logging service and the underlying Postgres table
definitions (``repositories/tables.py``); it is the only module in the codebase
allowed to issue ``food_entries`` SQL.
"""

from __future__ import annotations

import uuid
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.repositories.tables import daily_logs, food_entries
from diet_tracker_server.services.log_ids import daily_log_id as canonical_daily_log_id


def _food_entry_response_columns() -> tuple[Any, ...]:
    """Return the food-entry column projection matching ``FoodEntryResponse``.

    Internal-only columns are intentionally omitted so this projection is safe
    to use for any caller-facing endpoint.

    **Outputs:**
    - tuple[Any, ...]: Ordered SQLAlchemy column elements ready for ``select()``.
    """
    return (
        food_entries.c.id,
        food_entries.c.daily_log_id,
        food_entries.c.user_key,
        food_entries.c.entry_group_id,
        food_entries.c.display_name,
        food_entries.c.quantity_text,
        food_entries.c.normalized_quantity_value,
        food_entries.c.normalized_quantity_unit,
        food_entries.c.usda_fdc_id,
        food_entries.c.usda_description,
        food_entries.c.custom_food_id,
        food_entries.c.calories,
        food_entries.c.protein_g,
        food_entries.c.carbs_g,
        food_entries.c.fat_g,
        food_entries.c.meal_id,
        food_entries.c.meal_name,
        food_entries.c.consumed_at,
        food_entries.c.created_at,
    )


class EntriesRepository:
    def __init__(self, session: AsyncSession) -> None:
        """Bind the repository to an open async session.

        **Inputs:**
        - session (AsyncSession): SQLAlchemy async session used for all queries
          issued by this repository instance.
        """
        self._session = session

    @staticmethod
    def daily_log_id(user_key: str, log_date: DateValue) -> str:
        """Derive the deterministic UUID5 daily-log id for a user and date.

        Delegates to :func:`services.log_ids.daily_log_id` so the same hashing
        is used wherever the id is needed.

        **Inputs:**
        - user_key (str): Owning user identifier.
        - log_date (DateValue): Date associated with the daily log.

        **Outputs:**
        - str: UUID5 string derived from ``user_key`` and ``log_date``.
        """
        return canonical_daily_log_id(user_key, log_date)

    async def ensure_daily_log(self, daily_log_id: str, user_key: str, log_date: DateValue) -> None:
        """Insert the daily-log row for a user/date pair if it does not exist.

        Uses ``ON CONFLICT DO NOTHING`` against the
        ``(user_key, log_date)`` unique index so the call is idempotent.

        **Inputs:**
        - daily_log_id (str): UUID string for the daily-log primary key.
        - user_key (str): Owning user identifier.
        - log_date (DateValue): Date represented by the daily log.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        stmt = (
            pg_insert(daily_logs)
            .values(id=daily_log_id, user_key=user_key, log_date=log_date)
            .on_conflict_do_nothing(index_elements=[daily_logs.c.user_key, daily_logs.c.log_date])
        )
        await self._session.execute(stmt)

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
        usda_fdc_id: int | None,
        usda_description: str | None,
        custom_food_id: UUID | None,
        calories: int,
        protein_g: float,
        carbs_g: float,
        fat_g: float,
        consumed_at: DateTimeValue,
        meal_id: UUID | None = None,
        meal_name: str | None = None,
    ) -> dict[str, Any]:
        """Insert a food-entry row and return the inserted record.

        **Inputs:**
        - entry_id (uuid.UUID): UUID for the entry primary key.
        - daily_log_id (str): UUID string for the owning daily log.
        - user_key (str): Owning user identifier.
        - entry_group_id (uuid.UUID): UUID grouping related entries.
        - display_name (str): User-facing label for the consumed item.
        - quantity_text (str): Original quantity phrase supplied by the user.
        - normalized_quantity_value (float | None): Parsed numeric quantity
          when available.
        - normalized_quantity_unit (str | None): Parsed quantity unit when
          available.
        - usda_fdc_id (int | None): USDA FDC identifier when the entry maps to
          a USDA food.
        - usda_description (str | None): USDA description when the entry maps
          to a USDA food.
        - custom_food_id (UUID | None): Custom-food identifier when the entry
          maps to a user-defined food.
        - calories (int): Calories for this entry.
        - protein_g (float): Protein grams for this entry.
        - carbs_g (float): Carbohydrate grams for this entry.
        - fat_g (float): Fat grams for this entry.
        - consumed_at (DateTimeValue): Timestamp when the food was consumed.
        - meal_id (UUID | None): Optional meal UUID to associate the entry
          with a meal.
        - meal_name (str | None): Optional meal-name snapshot at entry
          creation time.

        **Outputs:**
        - dict[str, Any]: The inserted food-entry row as a mapping.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails
          (including the exactly-one-of source CHECK constraint).
        """
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
                custom_food_id=custom_food_id,
                calories=calories,
                protein_g=protein_g,
                carbs_g=carbs_g,
                fat_g=fat_g,
                consumed_at=consumed_at,
                meal_id=meal_id,
                meal_name=meal_name,
            )
            .returning(*_food_entry_response_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().one()
        return dict(row)

    async def list_entries_by_daily_log_id(self, daily_log_id: str) -> list[dict[str, Any]]:
        """List entries for a daily log ordered by consumption timestamp.

        **Inputs:**
        - daily_log_id (str): UUID string of the daily log to query.

        **Outputs:**
        - list[dict[str, Any]]: Ordered food-entry rows for that daily log.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        stmt = (
            select(*_food_entry_response_columns())
            .where(food_entries.c.daily_log_id == daily_log_id)
            .order_by(food_entries.c.consumed_at, food_entries.c.id)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    async def delete_entry(self, entry_id: UUID) -> bool:
        """Delete a food entry by primary key.

        **Inputs:**
        - entry_id (UUID): UUID of the food-entry row to delete.

        **Outputs:**
        - bool: ``True`` when a row was deleted, otherwise ``False``.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        stmt = delete(food_entries).where(food_entries.c.id == entry_id).returning(food_entries.c.id)
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None
