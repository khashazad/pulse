"""Food-memory persistence layer.

Provides :class:`FoodMemoryRepository`, which owns every SQL statement against
the ``food_memory`` table: upsert of USDA-pointer or custom-food-pointer
entries, name/alias lookup (with optional left-join to ``custom_foods`` for the
linked macro snapshot), listing per user, deletion, and alias-array mutation.

Sits between the food-memory service and the underlying Postgres table
definitions (``repositories/tables.py``); it is the only module in the codebase
allowed to issue ``food_memory`` SQL.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy import delete, func, or_, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.repositories.tables import custom_foods, food_memory

# Columns of a USDA-pointer memory row whose value carries over from the INSERT
# into the ON CONFLICT update. Declared once and reused to build both the
# ``.values()`` payload and the ``SET`` mapping so each column is named once.
_USDA_UPSERT_COLUMNS: tuple[str, ...] = (
    "name",
    "usda_fdc_id",
    "usda_description",
    "basis",
    "serving_size",
    "serving_size_unit",
    "calories",
    "protein_g",
    "carbs_g",
    "fat_g",
)


def _row_columns() -> tuple[Any, ...]:
    """Return the canonical column projection for ``food_memory`` rows.

    **Outputs:**
    - tuple[Any, ...]: Ordered SQLAlchemy column elements ready for ``select()``.
    """
    return (
        food_memory.c.id,
        food_memory.c.user_key,
        food_memory.c.name,
        food_memory.c.normalized_name,
        food_memory.c.usda_fdc_id,
        food_memory.c.usda_description,
        food_memory.c.custom_food_id,
        food_memory.c.food_id,
        food_memory.c.basis,
        food_memory.c.serving_size,
        food_memory.c.serving_size_unit,
        food_memory.c.calories,
        food_memory.c.protein_g,
        food_memory.c.carbs_g,
        food_memory.c.fat_g,
        food_memory.c.aliases,
        food_memory.c.created_at,
        food_memory.c.updated_at,
    )


class FoodMemoryRepository:
    def __init__(self, session: AsyncSession) -> None:
        """Bind the repository to an open async session.

        **Inputs:**
        - session (AsyncSession): SQLAlchemy async session used for all queries
          issued by this repository instance.
        """
        self._session = session

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
        aliases: list[str] | None = None,
    ) -> dict[str, Any]:
        """Upsert a USDA-pointer memory entry, replacing any prior row on the same name.

        The ``aliases`` argument is only written when explicitly supplied, so
        callers that don't touch aliases will not clobber an existing list.

        **Inputs:**
        - user_key (str): Owning user.
        - name (str): Original-cased phrase.
        - normalized_name (str): Lookup key.
        - usda_fdc_id (int): USDA FDC identifier.
        - usda_description (str): USDA description (immutable receipt).
        - basis (str): Macro basis (``per_100g``/``per_serving``/``per_unit``).
        - serving_size (float | None): Optional serving size.
        - serving_size_unit (str | None): Optional serving size unit.
        - calories (int): Calories at the indicated basis.
        - protein_g (float): Protein grams at the indicated basis.
        - carbs_g (float): Carbohydrate grams at the indicated basis.
        - fat_g (float): Fat grams at the indicated basis.
        - now (DateTimeValue): Timestamp for ``created_at``/``updated_at``.
        - aliases (list[str] | None): Optional alias array to overwrite.

        **Outputs:**
        - dict[str, Any]: The upserted row.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        column_values: dict[str, Any] = {
            "name": name,
            "usda_fdc_id": usda_fdc_id,
            "usda_description": usda_description,
            "basis": basis,
            "serving_size": serving_size,
            "serving_size_unit": serving_size_unit,
            "calories": calories,
            "protein_g": protein_g,
            "carbs_g": carbs_g,
            "fat_g": fat_g,
        }
        values: dict[str, Any] = dict(
            user_key=user_key,
            normalized_name=normalized_name,
            custom_food_id=None,
            created_at=now,
            updated_at=now,
            **{col: column_values[col] for col in _USDA_UPSERT_COLUMNS},
        )
        if aliases is not None:
            values["aliases"] = aliases
        insert_stmt = pg_insert(food_memory).values(**values)
        set_: dict[str, Any] = {
            col: getattr(insert_stmt.excluded, col) for col in _USDA_UPSERT_COLUMNS
        }
        set_["custom_food_id"] = None
        set_["updated_at"] = now
        if aliases is not None:
            set_["aliases"] = insert_stmt.excluded.aliases
        stmt = insert_stmt.on_conflict_do_update(
            index_elements=[food_memory.c.user_key, food_memory.c.normalized_name],
            set_=set_,
        ).returning(*_row_columns())
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())

    async def upsert_custom(
        self,
        user_key: str,
        name: str,
        normalized_name: str,
        custom_food_id: UUID,
        now: DateTimeValue,
    ) -> dict[str, Any]:
        """Upsert a custom-food-pointer memory entry; macros stay on the linked custom food.

        **Inputs:**
        - user_key (str): Owning user.
        - name (str): Original-cased phrase.
        - normalized_name (str): Lookup key.
        - custom_food_id (UUID): Linked custom food.
        - now (DateTimeValue): Timestamp for ``created_at``/``updated_at``.

        **Outputs:**
        - dict[str, Any]: The upserted row.
        """
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
                "food_id": None,
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

    async def get_by_name(self, user_key: str, normalized_name: str) -> dict[str, Any] | None:
        """Look up a memory entry by canonical name or alias.

        Outer-joins ``custom_foods`` so callers receive the linked custom-food
        macro snapshot in the same row when the memory entry points at one.

        **Inputs:**
        - user_key (str): Owner.
        - normalized_name (str): Lookup key (matches either the canonical
          ``normalized_name`` or any element of the ``aliases`` array).

        **Outputs:**
        - dict[str, Any] | None: Combined row including custom-food macros
          when applicable, or ``None`` when no match exists.
        """
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
            .select_from(
                food_memory.outerjoin(
                    custom_foods, custom_foods.c.id == food_memory.c.custom_food_id
                )
            )
            .where(food_memory.c.user_key == user_key)
            .where(
                or_(
                    food_memory.c.normalized_name == normalized_name,
                    food_memory.c.aliases.any(normalized_name),
                )
            )
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def list_for_user(self, user_key: str) -> list[dict[str, Any]]:
        """List every memory entry for a user, ordered by name.

        **Inputs:**
        - user_key (str): Owner.

        **Outputs:**
        - list[dict[str, Any]]: Rows ordered by ``normalized_name``.
        """
        stmt = (
            select(*_row_columns())
            .where(food_memory.c.user_key == user_key)
            .order_by(food_memory.c.normalized_name)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    async def delete_by_name(self, user_key: str, normalized_name: str) -> bool:
        """Delete a memory entry by normalized name.

        **Inputs:**
        - user_key (str): Owner.
        - normalized_name (str): Lookup key.

        **Outputs:**
        - bool: ``True`` when a row was deleted.
        """
        stmt = (
            delete(food_memory)
            .where(food_memory.c.user_key == user_key)
            .where(food_memory.c.normalized_name == normalized_name)
            .returning(food_memory.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None

    async def add_alias(
        self,
        user_key: str,
        normalized_name: str,
        alias: str,
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        """Append ``alias`` to the row's aliases array, deduplicated.

        Uses ``array_append`` + ``unnest``/``DISTINCT`` so the alias is added
        only when not already present.

        **Inputs:**
        - user_key (str): Owner.
        - normalized_name (str): Canonical row identifier.
        - alias (str): Already-normalized alias to add.
        - now (DateTimeValue): Timestamp for ``updated_at``.

        **Outputs:**
        - dict[str, Any] | None: Updated row, or ``None`` if no such
          ``food_memory`` row exists.
        """
        stmt = (
            update(food_memory)
            .where(food_memory.c.user_key == user_key)
            .where(food_memory.c.normalized_name == normalized_name)
            .values(
                aliases=func.array(
                    select(func.unnest(func.array_append(food_memory.c.aliases, alias)))
                    .distinct()
                    .scalar_subquery()
                ),
                updated_at=now,
            )
            .returning(*_row_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def remove_alias(
        self,
        user_key: str,
        normalized_name: str,
        alias: str,
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        """Remove ``alias`` from the row's aliases array; no-op when absent.

        **Inputs:**
        - user_key (str): Owner.
        - normalized_name (str): Canonical row identifier.
        - alias (str): Already-normalized alias to remove.
        - now (DateTimeValue): Timestamp for ``updated_at``.

        **Outputs:**
        - dict[str, Any] | None: Updated row, or ``None`` if no such
          ``food_memory`` row exists.
        """
        stmt = (
            update(food_memory)
            .where(food_memory.c.user_key == user_key)
            .where(food_memory.c.normalized_name == normalized_name)
            .values(
                aliases=func.array_remove(food_memory.c.aliases, alias),
                updated_at=now,
            )
            .returning(*_row_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def upsert_food(
        self,
        user_key: str,
        name: str,
        normalized_name: str,
        food_id: UUID,
        now: DateTimeValue,
        aliases: list[str] | None = None,
    ) -> dict[str, Any]:
        """Upsert a Food-pointer memory entry; macros live on the Food's portions.

        **Inputs:**
        - user_key (str): Owning user.
        - name (str): Original-cased Food name.
        - normalized_name (str): Lookup key.
        - food_id (UUID): Linked Food.
        - now (DateTimeValue): Timestamp for ``created_at``/``updated_at``.
        - aliases (list[str] | None): Optional alias array to set.

        **Outputs:**
        - dict[str, Any]: The upserted row.
        """
        values: dict[str, Any] = dict(
            user_key=user_key,
            name=name,
            normalized_name=normalized_name,
            usda_fdc_id=None,
            usda_description=None,
            custom_food_id=None,
            food_id=food_id,
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
        if aliases is not None:
            values["aliases"] = aliases
        insert_stmt = pg_insert(food_memory).values(**values)
        set_: dict[str, Any] = {
            "name": insert_stmt.excluded.name,
            "usda_fdc_id": None,
            "usda_description": None,
            "custom_food_id": None,
            "food_id": insert_stmt.excluded.food_id,
            "basis": None,
            "serving_size": None,
            "serving_size_unit": None,
            "calories": None,
            "protein_g": None,
            "carbs_g": None,
            "fat_g": None,
            "updated_at": now,
        }
        if aliases is not None:
            set_["aliases"] = insert_stmt.excluded.aliases
        stmt = insert_stmt.on_conflict_do_update(
            index_elements=[food_memory.c.user_key, food_memory.c.normalized_name],
            set_=set_,
        ).returning(*_row_columns())
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())

    async def get_by_food_id(self, user_key: str, food_id: UUID) -> dict[str, Any] | None:
        """Fetch the memory entry pointing at a Food (carries its aliases).

        **Inputs:**
        - user_key (str): Owner.
        - food_id (UUID): Linked Food.

        **Outputs:**
        - dict[str, Any] | None: Row when found, else ``None``.
        """
        stmt = (
            select(*_row_columns())
            .where(food_memory.c.user_key == user_key)
            .where(food_memory.c.food_id == food_id)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None
