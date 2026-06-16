"""Custom-food persistence layer.

Provides :class:`CustomFoodsRepository`, which owns every SQL statement against
the ``custom_foods`` table: insert/upsert keyed by ``(user_key,
normalized_name)``, lookup by id or name, listing per user, partial-field
update, and constrained delete.

Sits between the custom-foods service and the underlying Postgres table
definition (``repositories/tables.py``); it is the only module in the codebase
allowed to issue ``custom_foods`` SQL.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy import delete, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.repositories.tables import custom_foods

# Columns whose value is overwritten when an upsert replaces an existing row.
# Declared once and reused to build both the INSERT ``.values()`` payload and
# the ``ON CONFLICT ... SET`` mapping so a column is never listed twice.
_CUSTOM_FOOD_MUTABLE_COLUMNS: tuple[str, ...] = (
    "name",
    "basis",
    "serving_size",
    "serving_size_unit",
    "calories",
    "protein_g",
    "carbs_g",
    "fat_g",
    "source",
    "notes",
)


def _row_columns() -> tuple[Any, ...]:
    """Return the canonical column projection for ``custom_foods`` rows.

    **Outputs:**
    - tuple[Any, ...]: Ordered SQLAlchemy column elements matching the public
      response schema.
    """
    return (
        custom_foods.c.id,
        custom_foods.c.user_key,
        custom_foods.c.name,
        custom_foods.c.normalized_name,
        custom_foods.c.basis,
        custom_foods.c.serving_size,
        custom_foods.c.serving_size_unit,
        custom_foods.c.calories,
        custom_foods.c.protein_g,
        custom_foods.c.carbs_g,
        custom_foods.c.fat_g,
        custom_foods.c.source,
        custom_foods.c.notes,
        custom_foods.c.food_id,
        custom_foods.c.portion_label,
        custom_foods.c.created_at,
        custom_foods.c.updated_at,
    )


class CustomFoodsRepository:
    def __init__(self, session: AsyncSession) -> None:
        """Bind the repository to an open async session.

        **Inputs:**
        - session (AsyncSession): SQLAlchemy async session used for all queries
          issued by this repository instance.
        """
        self._session = session

    async def _insert(
        self,
        user_key: str,
        name: str,
        normalized_name: str,
        basis: str,
        serving_size: float | None,
        serving_size_unit: str | None,
        calories: int,
        protein_g: float,
        carbs_g: float,
        fat_g: float,
        source: str,
        notes: str | None,
        now: DateTimeValue,
        on_conflict_update: bool,
    ) -> dict[str, Any]:
        """Insert a custom-food row, optionally updating on conflict.

        Shared implementation behind :meth:`create` and :meth:`upsert`. The
        macro/value columns are declared once via
        ``_CUSTOM_FOOD_MUTABLE_COLUMNS`` and reused for both the ``.values()``
        payload and the ``ON CONFLICT ... SET`` mapping.

        **Inputs:**
        - user_key (str): Owning user identifier.
        - name (str): Original-cased display name.
        - normalized_name (str): Lowercased canonical key for lookup.
        - basis (str): Macro basis indicator (``per_100g``/``per_serving``/``per_unit``).
        - serving_size (float | None): Serving size when basis requires it.
        - serving_size_unit (str | None): Serving size unit (e.g. ``"g"``, ``"wrap"``).
        - calories (int): Calories at the indicated basis.
        - protein_g (float): Protein grams at the indicated basis.
        - carbs_g (float): Carbohydrate grams at the indicated basis.
        - fat_g (float): Fat grams at the indicated basis.
        - source (str): Provenance label (``manual``/``photo``/``corrected``).
        - notes (str | None): Free-form note.
        - now (DateTimeValue): Timestamp for ``created_at`` and ``updated_at``.
        - on_conflict_update (bool): When ``True``, an existing row for the same
          ``(user_key, normalized_name)`` is updated; when ``False``, a
          conflict surfaces as an IntegrityError.

        **Outputs:**
        - dict[str, Any]: The inserted or upserted row.

        **Raises:**
        - sqlalchemy.exc.IntegrityError: Raised (when ``on_conflict_update`` is
          ``False``) if a row already exists for the same user+name.
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        mutable_values = {
            "name": name,
            "basis": basis,
            "serving_size": serving_size,
            "serving_size_unit": serving_size_unit,
            "calories": calories,
            "protein_g": protein_g,
            "carbs_g": carbs_g,
            "fat_g": fat_g,
            "source": source,
            "notes": notes,
        }
        insert_stmt = pg_insert(custom_foods).values(
            user_key=user_key,
            normalized_name=normalized_name,
            created_at=now,
            updated_at=now,
            **{col: mutable_values[col] for col in _CUSTOM_FOOD_MUTABLE_COLUMNS},
        )
        if on_conflict_update:
            set_: dict[str, Any] = {
                col: getattr(insert_stmt.excluded, col) for col in _CUSTOM_FOOD_MUTABLE_COLUMNS
            }
            set_["updated_at"] = now
            stmt = insert_stmt.on_conflict_do_update(
                index_elements=[custom_foods.c.user_key, custom_foods.c.normalized_name],
                set_=set_,
            ).returning(*_row_columns())
        else:
            stmt = insert_stmt.returning(*_row_columns())
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())

    async def create(
        self,
        user_key: str,
        name: str,
        normalized_name: str,
        basis: str,
        serving_size: float | None,
        serving_size_unit: str | None,
        calories: int,
        protein_g: float,
        carbs_g: float,
        fat_g: float,
        source: str,
        notes: str | None,
        now: DateTimeValue,
    ) -> dict[str, Any]:
        """Insert a custom-food row keyed by ``(user_key, normalized_name)``.

        Thin wrapper over :meth:`_insert` with conflict-update disabled, so a
        duplicate name surfaces as an IntegrityError.

        **Inputs:**
        - user_key (str): Owning user identifier.
        - name (str): Original-cased display name.
        - normalized_name (str): Lowercased canonical key for lookup.
        - basis (str): Macro basis indicator (``per_100g``/``per_serving``/``per_unit``).
        - serving_size (float | None): Serving size when basis requires it.
        - serving_size_unit (str | None): Serving size unit (e.g. ``"g"``, ``"wrap"``).
        - calories (int): Calories at the indicated basis.
        - protein_g (float): Protein grams at the indicated basis.
        - carbs_g (float): Carbohydrate grams at the indicated basis.
        - fat_g (float): Fat grams at the indicated basis.
        - source (str): Provenance label (``manual``/``photo``/``corrected``).
        - notes (str | None): Free-form note.
        - now (DateTimeValue): Timestamp for ``created_at`` and ``updated_at``.

        **Outputs:**
        - dict[str, Any]: The inserted row.

        **Raises:**
        - sqlalchemy.exc.IntegrityError: Raised when a row already exists for
          the same user+name.
        """
        return await self._insert(
            user_key=user_key,
            name=name,
            normalized_name=normalized_name,
            basis=basis,
            serving_size=serving_size,
            serving_size_unit=serving_size_unit,
            calories=calories,
            protein_g=protein_g,
            carbs_g=carbs_g,
            fat_g=fat_g,
            source=source,
            notes=notes,
            now=now,
            on_conflict_update=False,
        )

    async def upsert(
        self,
        user_key: str,
        name: str,
        normalized_name: str,
        basis: str,
        serving_size: float | None,
        serving_size_unit: str | None,
        calories: int,
        protein_g: float,
        carbs_g: float,
        fat_g: float,
        source: str,
        notes: str | None,
        now: DateTimeValue,
    ) -> dict[str, Any]:
        """Insert a custom food, updating an existing row on conflict.

        Thin wrapper over :meth:`_insert` with conflict-update enabled. Uses
        Postgres ``ON CONFLICT`` against the ``(user_key, normalized_name)``
        unique index.

        **Inputs:**
        - user_key (str): Owning user identifier.
        - name (str): Original-cased display name.
        - normalized_name (str): Lowercased canonical key for lookup.
        - basis (str): Macro basis indicator.
        - serving_size (float | None): Serving size when basis requires it.
        - serving_size_unit (str | None): Serving size unit.
        - calories (int): Calories at the indicated basis.
        - protein_g (float): Protein grams at the indicated basis.
        - carbs_g (float): Carbohydrate grams at the indicated basis.
        - fat_g (float): Fat grams at the indicated basis.
        - source (str): Provenance label.
        - notes (str | None): Free-form note.
        - now (DateTimeValue): Timestamp for ``created_at`` and ``updated_at``.

        **Outputs:**
        - dict[str, Any]: The upserted row.

        **Raises:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        return await self._insert(
            user_key=user_key,
            name=name,
            normalized_name=normalized_name,
            basis=basis,
            serving_size=serving_size,
            serving_size_unit=serving_size_unit,
            calories=calories,
            protein_g=protein_g,
            carbs_g=carbs_g,
            fat_g=fat_g,
            source=source,
            notes=notes,
            now=now,
            on_conflict_update=True,
        )

    async def get_by_id(self, custom_food_id: UUID, user_key: str) -> dict[str, Any] | None:
        """Fetch a custom food by primary key, scoped to the owning user.

        **Inputs:**
        - custom_food_id (UUID): Primary key.
        - user_key (str): Owner restriction.

        **Outputs:**
        - dict[str, Any] | None: Row when found, else ``None``.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        stmt = (
            select(*_row_columns())
            .where(custom_foods.c.id == custom_food_id)
            .where(custom_foods.c.user_key == user_key)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def get_by_name(self, user_key: str, normalized_name: str) -> dict[str, Any] | None:
        """Fetch a custom food by normalized name for a user.

        **Inputs:**
        - user_key (str): Owner restriction.
        - normalized_name (str): Lookup key.

        **Outputs:**
        - dict[str, Any] | None: Row when found, else ``None``.
        """
        stmt = (
            select(*_row_columns())
            .where(custom_foods.c.user_key == user_key)
            .where(custom_foods.c.normalized_name == normalized_name)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def list_for_user(self, user_key: str) -> list[dict[str, Any]]:
        """List all custom foods for a user, ordered by name.

        **Inputs:**
        - user_key (str): Owner restriction.

        **Outputs:**
        - list[dict[str, Any]]: Rows ordered by ``normalized_name``.
        """
        stmt = (
            select(*_row_columns())
            .where(custom_foods.c.user_key == user_key)
            .order_by(custom_foods.c.normalized_name)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    async def update_fields(
        self,
        custom_food_id: UUID,
        user_key: str,
        fields: dict[str, Any],
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        """Update a subset of fields on a custom food and return the row.

        When ``fields`` is empty the existing row is returned unchanged.
        ``updated_at`` is always set automatically.

        **Inputs:**
        - custom_food_id (UUID): Primary key.
        - user_key (str): Owner restriction.
        - fields (dict[str, Any]): Column→new-value updates.
        - now (DateTimeValue): Timestamp used for ``updated_at``.

        **Outputs:**
        - dict[str, Any] | None: Updated row, or ``None`` when not found.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        if not fields:
            return await self.get_by_id(custom_food_id, user_key)
        values = {**fields, "updated_at": now}
        stmt = (
            update(custom_foods)
            .where(custom_foods.c.id == custom_food_id)
            .where(custom_foods.c.user_key == user_key)
            .values(**values)
            .returning(*_row_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def delete(self, custom_food_id: UUID, user_key: str) -> bool:
        """Delete a custom food by primary key.

        **Inputs:**
        - custom_food_id (UUID): Primary key.
        - user_key (str): Owner restriction.

        **Outputs:**
        - bool: ``True`` when a row was deleted.

        **Exceptions:**
        - sqlalchemy.exc.IntegrityError: Raised when foreign-key ``RESTRICT``
          prevents deletion (the custom food is referenced by ``food_entries``
          or ``meal_items``).
        """
        stmt = (
            delete(custom_foods)
            .where(custom_foods.c.id == custom_food_id)
            .where(custom_foods.c.user_key == user_key)
            .returning(custom_foods.c.id)
        )
        try:
            result = await self._session.execute(stmt)
        except IntegrityError:
            raise
        return result.scalar_one_or_none() is not None

    async def set_food_link(
        self,
        custom_food_id: UUID,
        user_key: str,
        food_id: UUID | None,
        portion_label: str | None,
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        """Attach or detach a custom food from a Food portion.

        **Inputs:**
        - custom_food_id (UUID): Portion row primary key.
        - user_key (str): Owner restriction.
        - food_id (UUID | None): Parent Food id to link to, or ``None`` to detach the portion.
        - portion_label (str | None): Label within the Food (e.g. "medium").
        - now (DateTimeValue): Timestamp for ``updated_at``.

        **Outputs:**
        - dict[str, Any] | None: Updated row, or ``None`` when not found.
        """
        stmt = (
            update(custom_foods)
            .where(custom_foods.c.id == custom_food_id)
            .where(custom_foods.c.user_key == user_key)
            .values(food_id=food_id, portion_label=portion_label, updated_at=now)
            .returning(*_row_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def clear_food_link_for_food(
        self, food_id: UUID, user_key: str, now: DateTimeValue
    ) -> list[dict[str, Any]]:
        """Detach every portion of a Food (ungroup), returning the freed rows.

        **Inputs:**
        - food_id (UUID): Parent Food id whose portions are released.
        - user_key (str): Owner restriction.
        - now (DateTimeValue): Timestamp for ``updated_at``.

        **Outputs:**
        - list[dict[str, Any]]: The custom-food rows that were detached.
        """
        stmt = (
            update(custom_foods)
            .where(custom_foods.c.food_id == food_id)
            .where(custom_foods.c.user_key == user_key)
            .values(food_id=None, portion_label=None, updated_at=now)
            .returning(*_row_columns())
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    async def list_by_food(self, food_id: UUID) -> list[dict[str, Any]]:
        """List a Food's portions ordered by label then name.

        **Inputs:**
        - food_id (UUID): Parent Food id.

        **Outputs:**
        - list[dict[str, Any]]: Portion rows.
        """
        stmt = (
            select(*_row_columns())
            .where(custom_foods.c.food_id == food_id)
            .order_by(custom_foods.c.portion_label, custom_foods.c.normalized_name)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    async def list_standalone(self, user_key: str) -> list[dict[str, Any]]:
        """List ungrouped custom foods (``food_id`` null) for a user.

        **Inputs:**
        - user_key (str): Owner restriction.

        **Outputs:**
        - list[dict[str, Any]]: Standalone rows ordered by name.
        """
        stmt = (
            select(*_row_columns())
            .where(custom_foods.c.user_key == user_key)
            .where(custom_foods.c.food_id.is_(None))
            .order_by(custom_foods.c.normalized_name)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]
