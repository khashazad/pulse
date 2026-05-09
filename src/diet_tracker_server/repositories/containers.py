from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy import case, delete, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.repositories.tables import containers


def _summary_columns() -> tuple[Any, ...]:
    """Columns safe for list/get summaries — never the blob bytes."""
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
        self._session = session

    async def create(
        self,
        user_key: str,
        name: str,
        normalized_name: str,
        tare_weight_g: float,
        now: DateTimeValue,
    ) -> dict[str, Any]:
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
        stmt = (
            select(*_summary_columns())
            .where(containers.c.id == container_id)
            .where(containers.c.user_key == user_key)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def list_for_user(self, user_key: str) -> list[dict[str, Any]]:
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
