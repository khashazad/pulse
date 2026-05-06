from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.repositories.tables import custom_foods, food_memory


def _row_columns() -> tuple[Any, ...]:
    return (
        food_memory.c.id,
        food_memory.c.user_key,
        food_memory.c.name,
        food_memory.c.normalized_name,
        food_memory.c.usda_fdc_id,
        food_memory.c.usda_description,
        food_memory.c.custom_food_id,
        food_memory.c.basis,
        food_memory.c.serving_size,
        food_memory.c.serving_size_unit,
        food_memory.c.calories,
        food_memory.c.protein_g,
        food_memory.c.carbs_g,
        food_memory.c.fat_g,
        food_memory.c.created_at,
        food_memory.c.updated_at,
    )


class FoodMemoryRepository:
    # Summary: Initializes a food-memory repository bound to an active SQLAlchemy session.
    # Parameters:
    # - session (AsyncSession): SQLAlchemy async session.
    # Returns:
    # - None: Stores the session for subsequent method calls.
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    # Summary: Upserts a USDA-pointer memory entry, replacing any prior entry on the same name.
    # Parameters:
    # - user_key (str): Owning user.
    # - name (str): Original-cased phrase.
    # - normalized_name (str): Lookup key.
    # - usda_fdc_id (int): USDA FDC identifier.
    # - usda_description (str): USDA description (immutable receipt).
    # - basis (str): Macro basis (`per_100g`/`per_serving`/`per_unit`).
    # - serving_size/serving_size_unit: Optional serving info.
    # - calories/protein_g/carbs_g/fat_g: Macros at the indicated basis.
    # - now (DateTimeValue): Timestamp.
    # Returns:
    # - dict[str, Any]: Upserted row.
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    async def upsert_usda(
        self,
        user_key: str,
        name: str,
        normalized_name: str,
        usda_fdc_id: int,
        usda_description: str,
        basis: str,
        serving_size: float | None,
        serving_size_unit: str | None,
        calories: int,
        protein_g: float,
        carbs_g: float,
        fat_g: float,
        now: DateTimeValue,
    ) -> dict[str, Any]:
        insert_stmt = pg_insert(food_memory).values(
            user_key=user_key,
            name=name,
            normalized_name=normalized_name,
            usda_fdc_id=usda_fdc_id,
            usda_description=usda_description,
            custom_food_id=None,
            basis=basis,
            serving_size=serving_size,
            serving_size_unit=serving_size_unit,
            calories=calories,
            protein_g=protein_g,
            carbs_g=carbs_g,
            fat_g=fat_g,
            created_at=now,
            updated_at=now,
        )
        stmt = insert_stmt.on_conflict_do_update(
            index_elements=[food_memory.c.user_key, food_memory.c.normalized_name],
            set_={
                "name": insert_stmt.excluded.name,
                "usda_fdc_id": insert_stmt.excluded.usda_fdc_id,
                "usda_description": insert_stmt.excluded.usda_description,
                "custom_food_id": None,
                "basis": insert_stmt.excluded.basis,
                "serving_size": insert_stmt.excluded.serving_size,
                "serving_size_unit": insert_stmt.excluded.serving_size_unit,
                "calories": insert_stmt.excluded.calories,
                "protein_g": insert_stmt.excluded.protein_g,
                "carbs_g": insert_stmt.excluded.carbs_g,
                "fat_g": insert_stmt.excluded.fat_g,
                "updated_at": now,
            },
        ).returning(*_row_columns())
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())

    # Summary: Upserts a custom-food-pointer memory entry; macros remain on the linked custom food.
    # Parameters:
    # - user_key (str): Owning user.
    # - name (str): Original-cased phrase.
    # - normalized_name (str): Lookup key.
    # - custom_food_id (UUID): Linked custom food.
    # - now (DateTimeValue): Timestamp.
    # Returns:
    # - dict[str, Any]: Upserted row.
    async def upsert_custom(
        self,
        user_key: str,
        name: str,
        normalized_name: str,
        custom_food_id: UUID,
        now: DateTimeValue,
    ) -> dict[str, Any]:
        insert_stmt = pg_insert(food_memory).values(
            user_key=user_key,
            name=name,
            normalized_name=normalized_name,
            usda_fdc_id=None,
            usda_description=None,
            custom_food_id=custom_food_id,
            basis=None,
            serving_size=None,
            serving_size_unit=None,
            calories=None,
            protein_g=None,
            carbs_g=None,
            fat_g=None,
            created_at=now,
            updated_at=now,
        )
        stmt = insert_stmt.on_conflict_do_update(
            index_elements=[food_memory.c.user_key, food_memory.c.normalized_name],
            set_={
                "name": insert_stmt.excluded.name,
                "usda_fdc_id": None,
                "usda_description": None,
                "custom_food_id": insert_stmt.excluded.custom_food_id,
                "basis": None,
                "serving_size": None,
                "serving_size_unit": None,
                "calories": None,
                "protein_g": None,
                "carbs_g": None,
                "fat_g": None,
                "updated_at": now,
            },
        ).returning(*_row_columns())
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())

    # Summary: Looks up a memory entry by normalized name. Joins `custom_foods` for the macro snapshot
    # when the entry points at a custom food.
    # Parameters:
    # - user_key (str): Owner.
    # - normalized_name (str): Lookup key.
    # Returns:
    # - dict[str, Any] | None: Combined row including custom-food macros when applicable, or None.
    async def get_by_name(self, user_key: str, normalized_name: str) -> dict[str, Any] | None:
        stmt = (
            select(
                *_row_columns(),
                custom_foods.c.id.label("cf_id"),
                custom_foods.c.user_key.label("cf_user_key"),
                custom_foods.c.name.label("cf_name"),
                custom_foods.c.normalized_name.label("cf_normalized_name"),
                custom_foods.c.basis.label("cf_basis"),
                custom_foods.c.serving_size.label("cf_serving_size"),
                custom_foods.c.serving_size_unit.label("cf_serving_size_unit"),
                custom_foods.c.calories.label("cf_calories"),
                custom_foods.c.protein_g.label("cf_protein_g"),
                custom_foods.c.carbs_g.label("cf_carbs_g"),
                custom_foods.c.fat_g.label("cf_fat_g"),
                custom_foods.c.source.label("cf_source"),
                custom_foods.c.notes.label("cf_notes"),
                custom_foods.c.created_at.label("cf_created_at"),
                custom_foods.c.updated_at.label("cf_updated_at"),
            )
            .select_from(food_memory.outerjoin(custom_foods, custom_foods.c.id == food_memory.c.custom_food_id))
            .where(food_memory.c.user_key == user_key)
            .where(food_memory.c.normalized_name == normalized_name)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    # Summary: Lists all memory entries for a user.
    # Parameters:
    # - user_key (str): Owner.
    # Returns:
    # - list[dict[str, Any]]: Rows ordered by normalized_name.
    async def list_for_user(self, user_key: str) -> list[dict[str, Any]]:
        stmt = (
            select(*_row_columns())
            .where(food_memory.c.user_key == user_key)
            .order_by(food_memory.c.normalized_name)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    # Summary: Deletes a memory entry by normalized name.
    # Parameters:
    # - user_key (str): Owner.
    # - normalized_name (str): Lookup key.
    # Returns:
    # - bool: True when a row was deleted.
    async def delete_by_name(self, user_key: str, normalized_name: str) -> bool:
        stmt = (
            delete(food_memory)
            .where(food_memory.c.user_key == user_key)
            .where(food_memory.c.normalized_name == normalized_name)
            .returning(food_memory.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None
