"""Progress-photo persistence layer.

Provides :class:`ProgressPhotoRepository`, which owns every SQL statement
against the ``progress_photos`` table: insert keyed by ``photo_id`` (one row
per photo — multiple per ``(user_key, log_date, tag_id)`` are allowed),
metadata listing across a date range, photo / thumbnail blob fetch, and
deletion by photo id.

Sits between the progress-photo service and the underlying Postgres table
definition (``repositories/tables.py``); it is the only module in the codebase
allowed to issue ``progress_photos`` SQL.
"""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.repositories.tables import progress_photos


def _summary_columns() -> tuple[Any, ...]:
    """Return the projection used for list / insert responses.

    Excludes the ``photo`` / ``photo_thumb`` blob columns so summary endpoints
    never accidentally stream binary data.

    **Outputs:**
    - tuple[Any, ...]: Ordered SQLAlchemy column elements ready for ``select()``.
    """
    return (
        progress_photos.c.id,
        progress_photos.c.user_key,
        progress_photos.c.log_date,
        progress_photos.c.tag_id,
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

    async def insert(
        self,
        *,
        user_key: str,
        log_date: DateValue,
        tag_id: UUID,
        photo: bytes,
        photo_thumb: bytes,
        photo_mime: str,
        bytes_: int,
        sha256: str,
        now: DateTimeValue,
        idempotency_key: UUID | None = None,
    ) -> dict[str, Any]:
        """Insert a new progress-photo row, returning its summary projection.

        Unlike the previous slot-based model there is no per-day uniqueness:
        a user may persist many photos for the same ``(log_date, tag_id)``.
        When ``idempotency_key`` is supplied, the row is deduped against the
        partial unique index ``uq_progress_photos_user_idem`` so retries by
        the offline upload queue return the previously-inserted row instead
        of creating a duplicate.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - log_date (DateValue): Calendar date the photo belongs to.
        - tag_id (UUID): FK into ``progress_photo_tags``.
        - photo (bytes): Full-resolution photo bytes.
        - photo_thumb (bytes): Thumbnail bytes.
        - photo_mime (str): MIME type for the stored image.
        - bytes_ (int): Byte length of ``photo`` for metadata reporting.
        - sha256 (str): Hex digest of the photo content for client cache keys.
        - now (DateTimeValue): Timestamp for ``created_at``/``updated_at``.
        - idempotency_key (UUID | None): Optional client-supplied dedup key.
          When set, a second call with the same ``(user_key, idempotency_key)``
          returns the existing row instead of inserting a duplicate.

        **Outputs:**
        - dict[str, Any]: Summary row of the inserted (or pre-existing) record.
        """
        values = {
            "user_key": user_key,
            "log_date": log_date,
            "tag_id": tag_id,
            "photo": photo,
            "photo_thumb": photo_thumb,
            "photo_mime": photo_mime,
            "bytes": bytes_,
            "sha256": sha256,
            "created_at": now,
            "updated_at": now,
            "idempotency_key": idempotency_key,
        }
        stmt = pg_insert(progress_photos).values(**values)
        if idempotency_key is not None:
            # No-op SET so RETURNING fires on conflict and gives us the existing row.
            stmt = stmt.on_conflict_do_update(
                index_elements=[
                    progress_photos.c.user_key,
                    progress_photos.c.idempotency_key,
                ],
                index_where=progress_photos.c.idempotency_key.isnot(None),
                set_={"updated_at": progress_photos.c.updated_at},
            )
        returning_stmt = stmt.returning(*_summary_columns())
        result = await self._session.execute(returning_stmt)
        return dict(result.mappings().one())

    async def list_metadata(
        self, *, user_key: str, frm: DateValue, to: DateValue
    ) -> list[dict[str, Any]]:
        """List progress-photo metadata for a user across an inclusive date range.

        Ordered by ``(log_date desc, tag_id asc, created_at asc)`` so callers
        receive a stable grouping by date then tag.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - frm (DateValue): Inclusive lower bound on ``log_date``.
        - to (DateValue): Inclusive upper bound on ``log_date``.

        **Outputs:**
        - list[dict[str, Any]]: Summary rows.
        """
        stmt = (
            select(*_summary_columns())
            .where(progress_photos.c.user_key == user_key)
            .where(progress_photos.c.log_date >= frm)
            .where(progress_photos.c.log_date <= to)
            .order_by(
                progress_photos.c.log_date.desc(),
                progress_photos.c.tag_id.asc(),
                progress_photos.c.created_at.asc(),
            )
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    async def get_photo(
        self, *, photo_id: UUID, user_key: str, thumb: bool
    ) -> dict[str, Any] | None:
        """Fetch the stored photo (or thumbnail) bytes plus cache headers.

        **Inputs:**
        - photo_id (UUID): Photo primary key.
        - user_key (str): Owning user's scoping key.
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
            .where(progress_photos.c.id == photo_id)
            .where(progress_photos.c.user_key == user_key)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def delete(self, *, photo_id: UUID, user_key: str) -> bool:
        """Remove a progress-photo row by id (scoped to its owner).

        **Inputs:**
        - photo_id (UUID): Photo primary key.
        - user_key (str): Owning user's scoping key.

        **Outputs:**
        - bool: ``True`` when a row was removed, ``False`` when no matching
          row existed.
        """
        stmt = (
            delete(progress_photos)
            .where(progress_photos.c.id == photo_id)
            .where(progress_photos.c.user_key == user_key)
            .returning(progress_photos.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None
