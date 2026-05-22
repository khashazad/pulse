"""Meals persistence layer.

Provides :class:`MealsRepository`, which owns every SQL statement against the
``meals`` and ``meal_items`` tables: meal CRUD, ordered item insertion with
position tracking, item updates/deletes, list with aggregate macro totals, and
alias-array mutation. Meal items store pre-scaled macros at create time so
logging a meal is a straight copy without re-scaling.

Sits between the meals service and the underlying Postgres table definitions
(``repositories/tables.py``); it is the only module in the codebase allowed to
issue ``meals`` / ``meal_items`` SQL.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy import Integer, cast, delete, func, or_, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.repositories.tables import meal_items, meals


def _meal_columns() -> tuple[Any, ...]:
    """Return the canonical column projection for ``meals`` rows.

    **Outputs:**
    - tuple[Any, ...]: Ordered SQLAlchemy column elements ready for ``select()``.
    """
    return (
        meals.c.id,
        meals.c.user_key,
        meals.c.name,
        meals.c.normalized_name,
        meals.c.notes,
        meals.c.aliases,
        meals.c.created_at,
        meals.c.updated_at,
    )


def _meal_item_columns() -> tuple[Any, ...]:
    """Return the canonical column projection for ``meal_items`` rows.

    **Outputs:**
    - tuple[Any, ...]: Ordered SQLAlchemy column elements ready for ``select()``.
    """
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
    def __init__(self, session: AsyncSession) -> None:
        """Bind the repository to an open async session.

        **Inputs:**
        - session (AsyncSession): SQLAlchemy async session used for all queries
          issued by this repository instance.
        """
        self._session = session

    async def create_meal(
        self,
        user_key: str,
        name: str,
        normalized_name: str,
        notes: str | None,
        now: DateTimeValue,
        aliases: list[str] | None = None,
    ) -> dict[str, Any]:
        """Insert a new meal row and return the inserted record.

        **Inputs:**
        - user_key (str): Owning user.
        - name (str): Original-cased display name.
        - normalized_name (str): Lookup key.
        - notes (str | None): Free-form note.
        - now (DateTimeValue): Timestamp for ``created_at``/``updated_at``.
        - aliases (list[str] | None): Optional alias array to seed.

        **Outputs:**
        - dict[str, Any]: The inserted meal row.
        """
        values: dict[str, Any] = dict(
            user_key=user_key,
            name=name,
            normalized_name=normalized_name,
            notes=notes,
            created_at=now,
            updated_at=now,
        )
        if aliases is not None:
            values["aliases"] = aliases
        stmt = (
            pg_insert(meals)
            .values(**values)
            .returning(*_meal_columns())
        )
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())

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
        """Insert a meal item at the given position with pre-scaled macros.

        **Inputs:**
        - meal_id (UUID): Owning meal id.
        - position (int): Ordinal position within the meal.
        - display_name (str): User-facing item label.
        - quantity_text (str): Original quantity phrase.
        - normalized_quantity_value (float | None): Parsed numeric quantity.
        - normalized_quantity_unit (str | None): Parsed unit.
        - usda_fdc_id (int | None): USDA FDC id when the item is a USDA food.
        - usda_description (str | None): USDA description snapshot.
        - custom_food_id (UUID | None): Custom-food id when the item is a
          user-defined food.
        - calories (int): Pre-scaled calories.
        - protein_g (float): Pre-scaled protein grams.
        - carbs_g (float): Pre-scaled carbohydrate grams.
        - fat_g (float): Pre-scaled fat grams.
        - now (DateTimeValue): Timestamp for ``created_at``.

        **Outputs:**
        - dict[str, Any]: The inserted meal-item row.
        """
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

    async def next_position(self, meal_id: UUID) -> int:
        """Return the next free position index for a meal.

        **Inputs:**
        - meal_id (UUID): Meal whose items to inspect.

        **Outputs:**
        - int: ``max(position)+1``, or ``0`` when the meal has no items yet.
        """
        stmt = select(func.coalesce(func.max(meal_items.c.position), -1) + 1).where(meal_items.c.meal_id == meal_id)
        result = await self._session.execute(stmt)
        return int(result.scalar_one())

    async def get_meal(self, meal_id: UUID, user_key: str) -> dict[str, Any] | None:
        """Fetch a meal by primary key, restricted to the owning user.

        **Inputs:**
        - meal_id (UUID): Primary key.
        - user_key (str): Owner restriction.

        **Outputs:**
        - dict[str, Any] | None: Meal row when found, else ``None``.
        """
        stmt = (
            select(*_meal_columns())
            .where(meals.c.id == meal_id)
            .where(meals.c.user_key == user_key)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def get_meal_by_name(self, user_key: str, normalized_name: str) -> dict[str, Any] | None:
        """Fetch a meal by canonical normalized name or alias.

        **Inputs:**
        - user_key (str): Owner restriction.
        - normalized_name (str): Lookup key (matches either the canonical
          ``normalized_name`` or any element of the ``aliases`` array).

        **Outputs:**
        - dict[str, Any] | None: Meal row when found, else ``None``.
        """
        stmt = (
            select(*_meal_columns())
            .where(meals.c.user_key == user_key)
            .where(
                or_(
                    meals.c.normalized_name == normalized_name,
                    meals.c.aliases.any(normalized_name),
                )
            )
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def list_meals(self, user_key: str) -> list[dict[str, Any]]:
        """List meals for a user with item counts and macro totals.

        Outer-joins ``meal_items`` so meals with no items still appear with
        zero totals. Computed in a single SQL pass per call.

        **Inputs:**
        - user_key (str): Owner restriction.

        **Outputs:**
        - list[dict[str, Any]]: Meal summary rows ordered by ``normalized_name``.
        """
        stmt = (
            select(
                meals.c.id,
                meals.c.name,
                meals.c.normalized_name,
                meals.c.notes,
                meals.c.aliases,
                func.count(meal_items.c.id).label("item_count"),
                cast(func.coalesce(func.sum(meal_items.c.calories), 0), Integer).label("total_calories"),
                func.coalesce(func.sum(meal_items.c.protein_g), 0).label("total_protein_g"),
                func.coalesce(func.sum(meal_items.c.carbs_g), 0).label("total_carbs_g"),
                func.coalesce(func.sum(meal_items.c.fat_g), 0).label("total_fat_g"),
            )
            .select_from(meals.outerjoin(meal_items, meal_items.c.meal_id == meals.c.id))
            .where(meals.c.user_key == user_key)
            .group_by(meals.c.id, meals.c.name, meals.c.normalized_name, meals.c.notes, meals.c.aliases)
            .order_by(meals.c.normalized_name)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    async def list_items(self, meal_id: UUID) -> list[dict[str, Any]]:
        """List items for a meal in stored position order.

        **Inputs:**
        - meal_id (UUID): Owning meal id.

        **Outputs:**
        - list[dict[str, Any]]: Meal-item rows ordered by ``(position, id)``.
        """
        stmt = (
            select(*_meal_item_columns())
            .where(meal_items.c.meal_id == meal_id)
            .order_by(meal_items.c.position, meal_items.c.id)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    async def update_meal(
        self,
        meal_id: UUID,
        user_key: str,
        fields: dict[str, Any],
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        """Update a subset of a meal's mutable fields (name, notes, etc).

        When ``fields`` is empty the row is fetched and returned unchanged.

        **Inputs:**
        - meal_id (UUID): Primary key.
        - user_key (str): Owner restriction.
        - fields (dict[str, Any]): Column→new-value updates.
        - now (DateTimeValue): Timestamp for ``updated_at``.

        **Outputs:**
        - dict[str, Any] | None: Updated meal row, or ``None`` when not found.
        """
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

    async def update_meal_item(
        self,
        meal_item_id: UUID,
        meal_id: UUID,
        fields: dict[str, Any],
    ) -> dict[str, Any] | None:
        """Update a meal item's mutable fields.

        When ``fields`` is empty the existing row is fetched and returned
        unchanged.

        **Inputs:**
        - meal_item_id (UUID): Item primary key.
        - meal_id (UUID): Owning meal id used for safety scoping.
        - fields (dict[str, Any]): Column→new-value updates.

        **Outputs:**
        - dict[str, Any] | None: Updated meal-item row, or ``None`` when not found.
        """
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

    async def delete_meal(self, meal_id: UUID, user_key: str) -> bool:
        """Delete a meal (cascades to ``meal_items``).

        **Inputs:**
        - meal_id (UUID): Primary key.
        - user_key (str): Owner restriction.

        **Outputs:**
        - bool: ``True`` when a row was deleted.
        """
        stmt = (
            delete(meals)
            .where(meals.c.id == meal_id)
            .where(meals.c.user_key == user_key)
            .returning(meals.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None

    async def delete_meal_item(self, meal_item_id: UUID, meal_id: UUID) -> bool:
        """Delete one item from a meal.

        **Inputs:**
        - meal_item_id (UUID): Item primary key.
        - meal_id (UUID): Owning meal id used for safety scoping.

        **Outputs:**
        - bool: ``True`` when a row was deleted.
        """
        stmt = (
            delete(meal_items)
            .where(meal_items.c.id == meal_item_id)
            .where(meal_items.c.meal_id == meal_id)
            .returning(meal_items.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None

    async def add_alias(
        self,
        meal_id: UUID,
        user_key: str,
        alias: str,
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        """Append ``alias`` to the meal's aliases array, deduplicated.

        Uses ``array_append`` + ``unnest``/``DISTINCT`` so the alias is added
        only when not already present.

        **Inputs:**
        - meal_id (UUID): Primary key.
        - user_key (str): Owner restriction.
        - alias (str): Already-normalized alias to add.
        - now (DateTimeValue): Timestamp for ``updated_at``.

        **Outputs:**
        - dict[str, Any] | None: Updated meal row, or ``None`` when not found.
        """
        stmt = (
            update(meals)
            .where(meals.c.id == meal_id)
            .where(meals.c.user_key == user_key)
            .values(
                aliases=func.array(
                    select(func.unnest(func.array_append(meals.c.aliases, alias)))
                    .distinct()
                    .scalar_subquery()
                ),
                updated_at=now,
            )
            .returning(*_meal_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def remove_alias(
        self,
        meal_id: UUID,
        user_key: str,
        alias: str,
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        """Remove ``alias`` from the meal's aliases array; no-op when absent.

        **Inputs:**
        - meal_id (UUID): Primary key.
        - user_key (str): Owner restriction.
        - alias (str): Already-normalized alias to remove.
        - now (DateTimeValue): Timestamp for ``updated_at``.

        **Outputs:**
        - dict[str, Any] | None: Updated meal row, or ``None`` when not found.
        """
        stmt = (
            update(meals)
            .where(meals.c.id == meal_id)
            .where(meals.c.user_key == user_key)
            .values(
                aliases=func.array_remove(meals.c.aliases, alias),
                updated_at=now,
            )
            .returning(*_meal_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None
