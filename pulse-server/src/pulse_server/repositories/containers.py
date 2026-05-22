"""Container persistence layer.

Provides :class:`ContainersRepository`, which owns every SQL statement against
the ``containers`` table: CRUD on tare data plus separate handling of the
optional photo / thumbnail blob columns (kept out of summary projections to
avoid streaming binary data on list calls).

Sits between the containers service (``services/containers_service.py``) and
the underlying Postgres table definition (``repositories/tables.py``); it is
the only module in the codebase allowed to issue container-table SQL.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy import case, delete, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.repositories.tables import containers


def _summary_columns() -> tuple[Any, ...]:
    """Return the projection used by list/get responses.

    Excludes the ``photo``/``photo_thumb``/``photo_mime`` blob columns and
    surfaces a boolean ``has_photo`` flag instead so callers never accidentally
    stream binary data through summary endpoints.

    **Outputs:**
    - tuple[Any, ...]: Ordered SQLAlchemy column elements ready for ``select()``.
    """
    return (
        containers.c.id,
        containers.c.user_key,
        containers.c.name,
        containers.c.normalized_name,
        containers.c.tare_weight_g,
        case((containers.c.photo.isnot(None), True), else_=False).label("has_photo"),
        containers.c.created_at,
        containers.c.updated_at,
    )


class ContainersRepository:
    """Async SQLAlchemy queries for the `containers` table."""

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
        tare_weight_g: float,
        now: DateTimeValue,
    ) -> dict[str, Any]:
        """Insert a new container row and return its summary projection.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - name (str): Original-cased display name.
        - normalized_name (str): Lowercased canonical lookup key.
        - tare_weight_g (float): Empty-container weight in grams.
        - now (DateTimeValue): Timestamp recorded as both ``created_at`` and
          ``updated_at``.

        **Outputs:**
        - dict[str, Any]: Inserted row using the summary projection (no blob
          columns; ``has_photo`` boolean).
        """
        stmt = (
            pg_insert(containers)
            .values(
                user_key=user_key,
                name=name,
                normalized_name=normalized_name,
                tare_weight_g=tare_weight_g,
                created_at=now,
                updated_at=now,
            )
            .returning(*_summary_columns())
        )
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())

    async def get_by_id(self, container_id: UUID, user_key: str) -> dict[str, Any] | None:
        """Fetch a container by primary key, scoped to the owning user.

        **Inputs:**
        - container_id (UUID): Primary key.
        - user_key (str): Owning user's scoping key.

        **Outputs:**
        - dict[str, Any] | None: Summary row when found, else ``None``.
        """
        stmt = (
            select(*_summary_columns())
            .where(containers.c.id == container_id)
            .where(containers.c.user_key == user_key)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def list_for_user(self, user_key: str) -> list[dict[str, Any]]:
        """List every container owned by a user, ordered by normalized name.

        **Inputs:**
        - user_key (str): Owning user's scoping key.

        **Outputs:**
        - list[dict[str, Any]]: Summary rows ordered by ``normalized_name``;
          empty when the user has no containers.
        """
        stmt = (
            select(*_summary_columns())
            .where(containers.c.user_key == user_key)
            .order_by(containers.c.normalized_name)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    async def update_fields(
        self,
        container_id: UUID,
        user_key: str,
        fields: dict[str, Any],
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        """Apply a partial-field update and return the resulting row.

        When ``fields`` is empty the row is fetched and returned unchanged.
        ``updated_at`` is always set to ``now``.

        **Inputs:**
        - container_id (UUID): Primary key.
        - user_key (str): Owning user's scoping key.
        - fields (dict[str, Any]): Column→new-value updates.
        - now (DateTimeValue): Timestamp for ``updated_at``.

        **Outputs:**
        - dict[str, Any] | None: Updated summary row, or ``None`` when no
          matching row exists.
        """
        if not fields:
            return await self.get_by_id(container_id, user_key)
        values = {**fields, "updated_at": now}
        stmt = (
            update(containers)
            .where(containers.c.id == container_id)
            .where(containers.c.user_key == user_key)
            .values(**values)
            .returning(*_summary_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def delete(self, container_id: UUID, user_key: str) -> bool:
        """Delete a container scoped to its owner.

        **Inputs:**
        - container_id (UUID): Primary key.
        - user_key (str): Owning user's scoping key.

        **Outputs:**
        - bool: ``True`` when a row was removed, ``False`` when no matching
          row existed.
        """
        stmt = (
            delete(containers)
            .where(containers.c.id == container_id)
            .where(containers.c.user_key == user_key)
            .returning(containers.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None

    async def set_photo(
        self,
        container_id: UUID,
        user_key: str,
        photo: bytes,
        photo_thumb: bytes,
        mime: str,
        now: DateTimeValue,
    ) -> bool:
        """Store (or replace) the container's photo blob, thumbnail, and MIME.

        **Inputs:**
        - container_id (UUID): Primary key.
        - user_key (str): Owning user's scoping key.
        - photo (bytes): Full-resolution photo bytes.
        - photo_thumb (bytes): Thumbnail bytes.
        - mime (str): MIME type for the stored image.
        - now (DateTimeValue): Timestamp for ``updated_at``.

        **Outputs:**
        - bool: ``True`` when a row was updated, ``False`` when no matching
          row existed.
        """
        stmt = (
            update(containers)
            .where(containers.c.id == container_id)
            .where(containers.c.user_key == user_key)
            .values(photo=photo, photo_thumb=photo_thumb, photo_mime=mime, updated_at=now)
            .returning(containers.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None

    async def clear_photo(
        self,
        container_id: UUID,
        user_key: str,
        now: DateTimeValue,
    ) -> bool:
        """Null out the photo, thumbnail, and MIME columns for a container.

        **Inputs:**
        - container_id (UUID): Primary key.
        - user_key (str): Owning user's scoping key.
        - now (DateTimeValue): Timestamp for ``updated_at``.

        **Outputs:**
        - bool: ``True`` when a row was updated, ``False`` when no matching
          row existed.
        """
        stmt = (
            update(containers)
            .where(containers.c.id == container_id)
            .where(containers.c.user_key == user_key)
            .values(photo=None, photo_thumb=None, photo_mime=None, updated_at=now)
            .returning(containers.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None

    async def get_photo(
        self,
        container_id: UUID,
        user_key: str,
        thumb: bool,
    ) -> tuple[bytes, str] | None:
        """Fetch the stored photo (or thumbnail) bytes for a container.

        **Inputs:**
        - container_id (UUID): Primary key.
        - user_key (str): Owning user's scoping key.
        - thumb (bool): When ``True`` returns ``photo_thumb``; otherwise the
          full ``photo`` column.

        **Outputs:**
        - tuple[bytes, str] | None: ``(image_bytes, mime_type)`` when a photo
          is present (MIME defaults to ``"image/jpeg"`` when null); ``None``
          when no row matches or no photo is stored.
        """
        col = containers.c.photo_thumb if thumb else containers.c.photo
        stmt = (
            select(col, containers.c.photo_mime)
            .where(containers.c.id == container_id)
            .where(containers.c.user_key == user_key)
        )
        result = await self._session.execute(stmt)
        row = result.first()
        if row is None or row[0] is None:
            return None
        return bytes(row[0]), row[1] or "image/jpeg"
