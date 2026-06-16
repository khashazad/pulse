"""Foods (portion-parent) persistence layer.

Provides :class:`FoodsRepository`, the only module allowed to issue SQL against
the ``foods`` table: create, fetch by id, list per user, partial update, and
delete. Portion linkage lives on ``custom_foods`` and is owned by
:class:`CustomFoodsRepository`; this repository never writes ``custom_foods``.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy import delete, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.repositories.tables import foods


def _row_columns() -> tuple[Any, ...]:
    """Return the canonical column projection for ``foods`` rows.

    **Outputs:**
    - tuple[Any, ...]: Ordered SQLAlchemy column elements.
    """
    return (
        foods.c.id,
        foods.c.user_key,
        foods.c.name,
        foods.c.normalized_name,
        foods.c.notes,
        foods.c.default_portion_id,
        foods.c.created_at,
        foods.c.updated_at,
    )


class FoodsRepository:
    def __init__(self, session: AsyncSession) -> None:
        """Bind the repository to an open async session.

        **Inputs:**
        - session (AsyncSession): Session used for all queries.
        """
        self._session = session

    async def create(
        self,
        user_key: str,
        name: str,
        normalized_name: str,
        notes: str | None,
        now: DateTimeValue,
    ) -> dict[str, Any]:
        """Insert a Food row keyed by ``(user_key, normalized_name)``.

        **Inputs:**
        - user_key (str): Owning user.
        - name (str): Display name.
        - normalized_name (str): Lookup key.
        - notes (str | None): Optional note.
        - now (DateTimeValue): Timestamp for created/updated.

        **Outputs:**
        - dict[str, Any]: The inserted row.

        **Raises:**
        - sqlalchemy.exc.IntegrityError: When a Food with that name exists.
        """
        stmt = (
            pg_insert(foods)
            .values(
                user_key=user_key,
                name=name,
                normalized_name=normalized_name,
                notes=notes,
                created_at=now,
                updated_at=now,
            )
            .returning(*_row_columns())
        )
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())

    async def get_by_id(self, food_id: UUID, user_key: str) -> dict[str, Any] | None:
        """Fetch a Food by id, scoped to the user.

        **Inputs:**
        - food_id (UUID): Primary key.
        - user_key (str): Owner restriction.

        **Outputs:**
        - dict[str, Any] | None: Row or ``None``.
        """
        stmt = (
            select(*_row_columns()).where(foods.c.id == food_id).where(foods.c.user_key == user_key)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def list_for_user(self, user_key: str) -> list[dict[str, Any]]:
        """List all Foods for a user, ordered by name.

        **Inputs:**
        - user_key (str): Owner restriction.

        **Outputs:**
        - list[dict[str, Any]]: Rows ordered by ``normalized_name``.
        """
        stmt = (
            select(*_row_columns())
            .where(foods.c.user_key == user_key)
            .order_by(foods.c.normalized_name)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    async def update_fields(
        self,
        food_id: UUID,
        user_key: str,
        fields: dict[str, Any],
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        """Update a subset of a Food's fields; ``updated_at`` always set.

        **Inputs:**
        - food_id (UUID): Primary key.
        - user_key (str): Owner restriction.
        - fields (dict[str, Any]): Column→new-value updates.
        - now (DateTimeValue): Timestamp for ``updated_at``.

        **Outputs:**
        - dict[str, Any] | None: Updated row or ``None`` when not found.
        """
        if not fields:
            return await self.get_by_id(food_id, user_key)
        stmt = (
            update(foods)
            .where(foods.c.id == food_id)
            .where(foods.c.user_key == user_key)
            .values(**fields, updated_at=now)
            .returning(*_row_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def delete(self, food_id: UUID, user_key: str) -> bool:
        """Delete a Food row by id.

        **Inputs:**
        - food_id (UUID): Primary key.
        - user_key (str): Owner restriction.

        **Outputs:**
        - bool: ``True`` when a row was deleted.
        """
        stmt = (
            delete(foods)
            .where(foods.c.id == food_id)
            .where(foods.c.user_key == user_key)
            .returning(foods.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None
