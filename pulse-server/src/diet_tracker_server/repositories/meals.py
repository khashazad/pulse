from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy import delete, func, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.repositories.tables import meal_items, meals


def _meal_columns() -> tuple[Any, ...]:
    return (
        meals.c.id,
        meals.c.user_key,
        meals.c.name,
        meals.c.normalized_name,
        meals.c.notes,
        meals.c.created_at,
        meals.c.updated_at,
    )


def _meal_item_columns() -> tuple[Any, ...]:
    return (
        meal_items.c.id,
        meal_items.c.meal_id,
        meal_items.c.position,
        meal_items.c.display_name,
        meal_items.c.quantity_text,
        meal_items.c.normalized_quantity_value,
        meal_items.c.normalized_quantity_unit,
        meal_items.c.usda_fdc_id,
        meal_items.c.usda_description,
        meal_items.c.custom_food_id,
        meal_items.c.calories,
        meal_items.c.protein_g,
        meal_items.c.carbs_g,
        meal_items.c.fat_g,
        meal_items.c.created_at,
    )


class MealsRepository:
    # Summary: Initializes a meals repository bound to an active SQLAlchemy session.
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    # Summary: Creates a new meal row, returning the inserted record.
    async def create_meal(
        self,
        user_key: str,
        name: str,
        normalized_name: str,
        notes: str | None,
        now: DateTimeValue,
    ) -> dict[str, Any]:
        stmt = (
            pg_insert(meals)
            .values(
                user_key=user_key,
                name=name,
                normalized_name=normalized_name,
                notes=notes,
                created_at=now,
                updated_at=now,
            )
            .returning(*_meal_columns())
        )
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())

    # Summary: Inserts a meal item at the given position; macros are pre-scaled at create time.
    async def add_meal_item(
        self,
        meal_id: UUID,
        position: int,
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
        now: DateTimeValue,
    ) -> dict[str, Any]:
        stmt = (
            pg_insert(meal_items)
            .values(
                meal_id=meal_id,
                position=position,
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
                created_at=now,
            )
            .returning(*_meal_item_columns())
        )
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())

    # Summary: Returns the next position index for a meal (max+1, or 0 when empty).
    async def next_position(self, meal_id: UUID) -> int:
        stmt = select(func.coalesce(func.max(meal_items.c.position), -1) + 1).where(meal_items.c.meal_id == meal_id)
        result = await self._session.execute(stmt)
        return int(result.scalar_one())

    # Summary: Fetches a meal by primary key, restricted to the owning user.
    async def get_meal(self, meal_id: UUID, user_key: str) -> dict[str, Any] | None:
        stmt = (
            select(*_meal_columns())
            .where(meals.c.id == meal_id)
            .where(meals.c.user_key == user_key)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    # Summary: Fetches a meal by normalized name for a user.
    async def get_meal_by_name(self, user_key: str, normalized_name: str) -> dict[str, Any] | None:
        stmt = (
            select(*_meal_columns())
            .where(meals.c.user_key == user_key)
            .where(meals.c.normalized_name == normalized_name)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    # Summary: Lists meals owned by the user with their item counts (lightweight summary form).
    async def list_meals(self, user_key: str) -> list[dict[str, Any]]:
        stmt = (
            select(
                meals.c.id,
                meals.c.name,
                meals.c.normalized_name,
                meals.c.notes,
                func.count(meal_items.c.id).label("item_count"),
            )
            .select_from(meals.outerjoin(meal_items, meal_items.c.meal_id == meals.c.id))
            .where(meals.c.user_key == user_key)
            .group_by(meals.c.id, meals.c.name, meals.c.normalized_name, meals.c.notes)
            .order_by(meals.c.normalized_name)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    # Summary: Lists items for a meal in position order.
    async def list_items(self, meal_id: UUID) -> list[dict[str, Any]]:
        stmt = (
            select(*_meal_item_columns())
            .where(meal_items.c.meal_id == meal_id)
            .order_by(meal_items.c.position, meal_items.c.id)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    # Summary: Updates meal name/notes (subset of fields).
    async def update_meal(
        self,
        meal_id: UUID,
        user_key: str,
        fields: dict[str, Any],
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        if not fields:
            return await self.get_meal(meal_id, user_key)
        values = {**fields, "updated_at": now}
        stmt = (
            update(meals)
            .where(meals.c.id == meal_id)
            .where(meals.c.user_key == user_key)
            .values(**values)
            .returning(*_meal_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    # Summary: Updates a meal item's mutable fields.
    async def update_meal_item(
        self,
        meal_item_id: UUID,
        meal_id: UUID,
        fields: dict[str, Any],
    ) -> dict[str, Any] | None:
        if not fields:
            stmt = (
                select(*_meal_item_columns())
                .where(meal_items.c.id == meal_item_id)
                .where(meal_items.c.meal_id == meal_id)
            )
            result = await self._session.execute(stmt)
            row = result.mappings().first()
            return dict(row) if row else None
        stmt = (
            update(meal_items)
            .where(meal_items.c.id == meal_item_id)
            .where(meal_items.c.meal_id == meal_id)
            .values(**fields)
            .returning(*_meal_item_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    # Summary: Deletes a meal (cascades to meal_items).
    async def delete_meal(self, meal_id: UUID, user_key: str) -> bool:
        stmt = (
            delete(meals)
            .where(meals.c.id == meal_id)
            .where(meals.c.user_key == user_key)
            .returning(meals.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None

    # Summary: Deletes one item from a meal.
    async def delete_meal_item(self, meal_item_id: UUID, meal_id: UUID) -> bool:
        stmt = (
            delete(meal_items)
            .where(meal_items.c.id == meal_item_id)
            .where(meal_items.c.meal_id == meal_id)
            .returning(meal_items.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None
