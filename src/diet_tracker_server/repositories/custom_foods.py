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

from diet_tracker_server.repositories.tables import custom_foods


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

        **Exceptions:**
        - sqlalchemy.exc.IntegrityError: Raised when a row already exists for
          the same user+name.
        """
        stmt = (
            pg_insert(custom_foods)
            .values(
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
                created_at=now,
                updated_at=now,
            )
            .returning(*_row_columns())
        )
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())

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

        Uses Postgres ``ON CONFLICT`` against the
        ``(user_key, normalized_name)`` unique index.

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

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        insert_stmt = pg_insert(custom_foods).values(
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
            created_at=now,
            updated_at=now,
        )
        stmt = insert_stmt.on_conflict_do_update(
            index_elements=[custom_foods.c.user_key, custom_foods.c.normalized_name],
            set_={
                "name": insert_stmt.excluded.name,
                "basis": insert_stmt.excluded.basis,
                "serving_size": insert_stmt.excluded.serving_size,
                "serving_size_unit": insert_stmt.excluded.serving_size_unit,
                "calories": insert_stmt.excluded.calories,
                "protein_g": insert_stmt.excluded.protein_g,
                "carbs_g": insert_stmt.excluded.carbs_g,
                "fat_g": insert_stmt.excluded.fat_g,
                "source": insert_stmt.excluded.source,
                "notes": insert_stmt.excluded.notes,
                "updated_at": now,
            },
        ).returning(*_row_columns())
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())

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
