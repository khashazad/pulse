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
from dataclasses import dataclass
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy import delete, select
from sqlalchemy import func as sa_func
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.log_ids import daily_log_id as canonical_daily_log_id
from pulse_server.repositories.tables import daily_logs, food_entries


@dataclass(frozen=True)
class FoodEntryPayload:
    """Immutable bundle of the column values for a single ``food_entries`` insert.

    Groups the ~18 fields previously passed positionally/by keyword to
    :meth:`EntriesRepository.create_food_entry` into one frozen value object so
    the insert has a single, self-documenting parameter.

    **Inputs:**
    - entry_id (uuid.UUID): UUID for the entry primary key.
    - daily_log_id (str): UUID string for the owning daily log.
    - user_key (str): Owning user identifier.
    - entry_group_id (uuid.UUID): UUID grouping related entries.
    - display_name (str): User-facing label for the consumed item.
    - quantity_text (str): Original quantity phrase supplied by the user.
    - normalized_quantity_value (float | None): Parsed numeric quantity when
      available.
    - normalized_quantity_unit (str | None): Parsed quantity unit when
      available.
    - usda_fdc_id (int | None): USDA FDC identifier when the entry maps to a
      USDA food.
    - usda_description (str | None): USDA description when the entry maps to a
      USDA food.
    - custom_food_id (UUID | None): Custom-food identifier when the entry maps
      to a user-defined food.
    - calories (int): Calories for this entry.
    - protein_g (float): Protein grams for this entry.
    - carbs_g (float): Carbohydrate grams for this entry.
    - fat_g (float): Fat grams for this entry.
    - consumed_at (DateTimeValue): Timestamp when the food was consumed.
    - meal_id (UUID | None): Optional meal UUID associating the entry with a meal.
    - meal_name (str | None): Optional meal-name snapshot at entry creation time.
    """

    entry_id: uuid.UUID
    daily_log_id: str
    user_key: str
    entry_group_id: uuid.UUID
    display_name: str
    quantity_text: str
    normalized_quantity_value: float | None
    normalized_quantity_unit: str | None
    usda_fdc_id: int | None
    usda_description: str | None
    custom_food_id: UUID | None
    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float
    consumed_at: DateTimeValue
    meal_id: UUID | None = None
    meal_name: str | None = None


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

        Delegates to :func:`pulse_server.log_ids.daily_log_id` so the same
        hashing is used wherever the id is needed.

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

    async def create_food_entry(self, payload: FoodEntryPayload) -> dict[str, Any]:
        """Insert a food-entry row and return the inserted record.

        **Inputs:**
        - payload (FoodEntryPayload): Frozen bundle of all column values for
          the row (see :class:`FoodEntryPayload` for the per-field contract).

        **Outputs:**
        - dict[str, Any]: The inserted food-entry row as a mapping.

        **Raises:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails
          (including the exactly-one-of source CHECK constraint).
        """
        stmt = (
            pg_insert(food_entries)
            .values(
                id=payload.entry_id,
                daily_log_id=payload.daily_log_id,
                user_key=payload.user_key,
                entry_group_id=payload.entry_group_id,
                display_name=payload.display_name,
                quantity_text=payload.quantity_text,
                normalized_quantity_value=payload.normalized_quantity_value,
                normalized_quantity_unit=payload.normalized_quantity_unit,
                usda_fdc_id=payload.usda_fdc_id,
                usda_description=payload.usda_description,
                custom_food_id=payload.custom_food_id,
                calories=payload.calories,
                protein_g=payload.protein_g,
                carbs_g=payload.carbs_g,
                fat_g=payload.fat_g,
                consumed_at=payload.consumed_at,
                meal_id=payload.meal_id,
                meal_name=payload.meal_name,
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

    async def calorie_totals_by_day(
        self,
        user_key: str,
        from_date: DateValue,
        to_date: DateValue,
    ) -> list[dict[str, Any]]:
        """Sum food-entry calories per day within an inclusive date range.

        Joins ``food_entries`` to ``daily_logs`` so days with zero entries are
        omitted (callers fill gaps as needed).

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - from_date (DateValue): Inclusive lower bound on ``log_date``.
        - to_date (DateValue): Inclusive upper bound on ``log_date``.

        **Outputs:**
        - list[dict[str, Any]]: One mapping per day with at least one entry
          (keys ``log_date`` and ``calories``), ordered by ``log_date`` ascending.

        **Raises:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        stmt = (
            select(
                daily_logs.c.log_date.label("log_date"),
                sa_func.coalesce(sa_func.sum(food_entries.c.calories), 0).label("calories"),
            )
            .select_from(
                food_entries.join(daily_logs, daily_logs.c.id == food_entries.c.daily_log_id)
            )
            .where(daily_logs.c.user_key == user_key)
            .where(daily_logs.c.log_date >= from_date)
            .where(daily_logs.c.log_date <= to_date)
            .group_by(daily_logs.c.log_date)
            .order_by(daily_logs.c.log_date.asc())
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    async def delete_entry(self, entry_id: UUID, user_key: str) -> bool:
        """Delete a food entry by primary key.

        **Inputs:**
        - entry_id (UUID): UUID of the food-entry row to delete.
        - user_key (str): Owning user identifier used to scope the delete.

        **Outputs:**
        - bool: ``True`` when a row was deleted, otherwise ``False``.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        stmt = (
            delete(food_entries)
            .where(food_entries.c.id == entry_id)
            .where(food_entries.c.user_key == user_key)
            .returning(food_entries.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None
