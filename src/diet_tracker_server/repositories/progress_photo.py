"""Progress-photo persistence layer.

Provides :class:`ProgressPhotoRepository`, which owns every SQL statement
against the ``progress_photos`` table: upsert keyed by
``(user_key, log_date, slot)``, metadata listing across a date range, photo /
thumbnail blob fetch, and deletion.

Sits between the progress-photo service and the underlying Postgres table
definition (``repositories/tables.py``); it is the only module in the codebase
allowed to issue ``progress_photos`` SQL.
"""

from __future__ import annotations

from datetime import date as DateValue, datetime as DateTimeValue
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.repositories.tables import progress_photos


def _summary_columns() -> tuple[Any, ...]:
    """Return the projection used for list / upsert responses.

    Excludes the ``photo`` / ``photo_thumb`` blob columns so summary endpoints
    never accidentally stream binary data.

    **Outputs:**
    - tuple[Any, ...]: Ordered SQLAlchemy column elements ready for ``select()``.
    """
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
        """Bind the repository to an open async session.

        **Inputs:**
        - session (AsyncSession): SQLAlchemy async session used for all queries
          issued by this repository instance.
        """
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
        """Insert or replace the progress-photo row for ``(user_key, log_date, slot)``.

        Uses Postgres ``ON CONFLICT`` against the
        ``(user_key, log_date, slot)`` unique index so the call is idempotent
        per slot per day.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - log_date (DateValue): Calendar date the photo belongs to.
        - slot (str): Slot identifier (``front``/``left``/``right``/``back``).
        - photo (bytes): Full-resolution photo bytes.
        - photo_thumb (bytes): Thumbnail bytes.
        - photo_mime (str): MIME type for the stored image.
        - bytes_ (int): Byte length of ``photo`` for metadata reporting.
        - sha256 (str): Hex digest of the photo content for client cache keys.
        - now (DateTimeValue): Timestamp for ``created_at``/``updated_at``.

        **Outputs:**
        - dict[str, Any]: Summary row of the inserted/updated record (no blob
          columns).
        """
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
        """List progress-photo metadata for a user across an inclusive date range.

        Ordered by date descending then slot ascending. Blob columns are
        excluded.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - frm (DateValue): Inclusive lower bound on ``log_date``.
        - to (DateValue): Inclusive upper bound on ``log_date``.

        **Outputs:**
        - list[dict[str, Any]]: Summary rows ordered by
          ``(log_date desc, slot asc)``.
        """
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
        """Fetch the stored photo (or thumbnail) bytes plus cache headers.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - log_date (DateValue): Calendar date the photo belongs to.
        - slot (str): Slot identifier.
        - thumb (bool): When ``True`` returns the thumbnail column; otherwise
          the full photo column.

        **Outputs:**
        - dict[str, Any] | None: Mapping with ``photo`` bytes, ``photo_mime``,
          ``sha256``, and ``updated_at`` when a row exists; ``None`` otherwise.
        """
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
        """Remove the progress-photo row for ``(user_key, log_date, slot)``.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - log_date (DateValue): Calendar date the photo belongs to.
        - slot (str): Slot identifier.

        **Outputs:**
        - bool: ``True`` when a row was removed, ``False`` when no matching
          row existed.
        """
        stmt = (
            delete(progress_photos)
            .where(progress_photos.c.user_key == user_key)
            .where(progress_photos.c.log_date == log_date)
            .where(progress_photos.c.slot == slot)
            .returning(progress_photos.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None
