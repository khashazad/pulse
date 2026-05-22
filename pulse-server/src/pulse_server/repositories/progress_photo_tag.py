"""Persistence layer for the progress-photo tag catalog.

Provides :class:`ProgressPhotoTagRepository`, which owns every SQL statement
against the ``progress_photo_tags`` table: create, list, get-by-id, partial
update, and a helper to detect whether a tag is still referenced by any
photo (used to keep the FK ``ON DELETE RESTRICT`` semantics enforceable from
the service layer).

Sits between :mod:`services.progress_photo_tag_service` and the underlying
Postgres table definitions in :mod:`repositories.tables`.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.repositories.tables import progress_photo_tags, progress_photos


def _columns() -> tuple[Any, ...]:
    """Return the full projection for tag responses (all columns)."""
    return (
        progress_photo_tags.c.id,
        progress_photo_tags.c.user_key,
        progress_photo_tags.c.name,
        progress_photo_tags.c.normalized_name,
        progress_photo_tags.c.sort_order,
        progress_photo_tags.c.created_at,
        progress_photo_tags.c.updated_at,
    )


class ProgressPhotoTagRepository:
    def __init__(self, session: AsyncSession) -> None:
        """Bind the repository to an open async session.

        **Inputs:**
        - session (AsyncSession): SQLAlchemy async session used for all queries
          issued by this repository instance.
        """
        self._session = session

    async def list_for_user(self, user_key: str) -> list[dict[str, Any]]:
        """Return every tag owned by a user, ordered by ``(sort_order, normalized_name)``.

        **Inputs:**
        - user_key (str): Owning user's scoping key.

        **Outputs:**
        - list[dict[str, Any]]: Tag rows in catalog order; empty when none exist.
        """
        stmt = (
            select(*_columns())
            .where(progress_photo_tags.c.user_key == user_key)
            .order_by(
                progress_photo_tags.c.sort_order,
                progress_photo_tags.c.normalized_name,
            )
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    async def get_by_id(self, *, tag_id: UUID, user_key: str) -> dict[str, Any] | None:
        """Fetch a single tag by primary key, scoped to its owner.

        **Inputs:**
        - tag_id (UUID): Tag primary key.
        - user_key (str): Owning user's scoping key.

        **Outputs:**
        - dict[str, Any] | None: Tag row when found, else ``None``.
        """
        stmt = (
            select(*_columns())
            .where(progress_photo_tags.c.id == tag_id)
            .where(progress_photo_tags.c.user_key == user_key)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def create(
        self,
        *,
        user_key: str,
        name: str,
        normalized_name: str,
        sort_order: int,
        now: DateTimeValue,
    ) -> dict[str, Any]:
        """Insert a new tag row and return its full projection.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - name (str): Display name as supplied by the user.
        - normalized_name (str): Lowercased canonical lookup key.
        - sort_order (int): Position in the user's tag list.
        - now (DateTimeValue): Timestamp for ``created_at`` and ``updated_at``.

        **Outputs:**
        - dict[str, Any]: Inserted row.
        """
        stmt = (
            pg_insert(progress_photo_tags)
            .values(
                user_key=user_key,
                name=name,
                normalized_name=normalized_name,
                sort_order=sort_order,
                created_at=now,
                updated_at=now,
            )
            .returning(*_columns())
        )
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())

    async def update_fields(
        self,
        *,
        tag_id: UUID,
        user_key: str,
        fields: dict[str, Any],
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        """Apply a partial-field update and return the resulting row.

        When ``fields`` is empty the row is fetched and returned unchanged.

        **Inputs:**
        - tag_id (UUID): Tag primary key.
        - user_key (str): Owning user's scoping key.
        - fields (dict[str, Any]): Column→new-value updates.
        - now (DateTimeValue): Timestamp for ``updated_at``.

        **Outputs:**
        - dict[str, Any] | None: Updated row, or ``None`` when no row matches.
        """
        if not fields:
            return await self.get_by_id(tag_id=tag_id, user_key=user_key)
        values = {**fields, "updated_at": now}
        stmt = (
            update(progress_photo_tags)
            .where(progress_photo_tags.c.id == tag_id)
            .where(progress_photo_tags.c.user_key == user_key)
            .values(**values)
            .returning(*_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def bulk_seed_if_empty(
        self,
        *,
        user_key: str,
        defaults: list[tuple[str, str, int]],
        now: DateTimeValue,
    ) -> None:
        """Insert default tag rows for a user when their catalog is empty.

        Race-safe: the underlying unique index on
        ``(user_key, normalized_name)`` paired with ``on conflict do nothing``
        means a concurrent caller seeding the same defaults is a no-op.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - defaults (list[tuple[str, str, int]]): Sequence of
          ``(name, normalized_name, sort_order)`` triples to insert.
        - now (DateTimeValue): Timestamp for ``created_at`` and ``updated_at``.
        """
        if not defaults:
            return
        stmt = pg_insert(progress_photo_tags).values(
            [
                {
                    "user_key": user_key,
                    "name": name,
                    "normalized_name": normalized_name,
                    "sort_order": sort_order,
                    "created_at": now,
                    "updated_at": now,
                }
                for name, normalized_name, sort_order in defaults
            ]
        )
        stmt = stmt.on_conflict_do_nothing(
            index_elements=[
                progress_photo_tags.c.user_key,
                progress_photo_tags.c.normalized_name,
            ]
        )
        await self._session.execute(stmt)

    async def photo_count(self, *, tag_id: UUID, user_key: str) -> int:
        """Return the number of progress photos still referencing a tag.

        Used by the service layer to decide whether a tag is safe to mutate
        in ways that would orphan photos (kept around even though delete is
        not exposed publicly, to support future maintenance paths).

        **Inputs:**
        - tag_id (UUID): Tag primary key.
        - user_key (str): Owning user's scoping key.

        **Outputs:**
        - int: Count of photo rows whose ``tag_id`` matches.
        """
        from sqlalchemy import func as sa_func

        stmt = (
            select(sa_func.count())
            .select_from(progress_photos)
            .where(progress_photos.c.tag_id == tag_id)
            .where(progress_photos.c.user_key == user_key)
        )
        result = await self._session.execute(stmt)
        return int(result.scalar_one() or 0)
