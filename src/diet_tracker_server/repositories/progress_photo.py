"""SQLAlchemy-Core repository for ``progress_photos``."""

from __future__ import annotations

from datetime import date as DateValue, datetime as DateTimeValue
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.repositories.tables import progress_photos


def _summary_columns() -> tuple[Any, ...]:
    return (
        progress_photos.c.id,
        progress_photos.c.user_key,
        progress_photos.c.log_date,
        progress_photos.c.slot,
        progress_photos.c.photo_mime,
        progress_photos.c.bytes,
        progress_photos.c.sha256,
        progress_photos.c.created_at,
        progress_photos.c.updated_at,
    )


class ProgressPhotoRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def upsert(
        self,
        *,
        user_key: str,
        log_date: DateValue,
        slot: str,
        photo: bytes,
        photo_thumb: bytes,
        photo_mime: str,
        bytes_: int,
        sha256: str,
        now: DateTimeValue,
    ) -> dict[str, Any]:
        stmt = (
            pg_insert(progress_photos)
            .values(
                user_key=user_key,
                log_date=log_date,
                slot=slot,
                photo=photo,
                photo_thumb=photo_thumb,
                photo_mime=photo_mime,
                bytes=bytes_,
                sha256=sha256,
                created_at=now,
                updated_at=now,
            )
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=[
                progress_photos.c.user_key,
                progress_photos.c.log_date,
                progress_photos.c.slot,
            ],
            set_={
                "photo": stmt.excluded.photo,
                "photo_thumb": stmt.excluded.photo_thumb,
                "photo_mime": stmt.excluded.photo_mime,
                "bytes": stmt.excluded.bytes,
                "sha256": stmt.excluded.sha256,
                "updated_at": stmt.excluded.updated_at,
            },
        ).returning(*_summary_columns())
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())

    async def list_metadata(
        self, *, user_key: str, frm: DateValue, to: DateValue
    ) -> list[dict[str, Any]]:
        stmt = (
            select(*_summary_columns())
            .where(progress_photos.c.user_key == user_key)
            .where(progress_photos.c.log_date >= frm)
            .where(progress_photos.c.log_date <= to)
            .order_by(progress_photos.c.log_date.desc(), progress_photos.c.slot.asc())
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    async def get_photo(
        self, *, user_key: str, log_date: DateValue, slot: str, thumb: bool
    ) -> dict[str, Any] | None:
        col = progress_photos.c.photo_thumb if thumb else progress_photos.c.photo
        stmt = (
            select(
                col.label("photo"),
                progress_photos.c.photo_mime,
                progress_photos.c.sha256,
                progress_photos.c.updated_at,
            )
            .where(progress_photos.c.user_key == user_key)
            .where(progress_photos.c.log_date == log_date)
            .where(progress_photos.c.slot == slot)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def delete(
        self, *, user_key: str, log_date: DateValue, slot: str
    ) -> bool:
        stmt = (
            delete(progress_photos)
            .where(progress_photos.c.user_key == user_key)
            .where(progress_photos.c.log_date == log_date)
            .where(progress_photos.c.slot == slot)
            .returning(progress_photos.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None
