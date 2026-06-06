"""Progress-photo persistence layer.

Provides :class:`ProgressPhotoRepository`, which owns every SQL statement
against the ``progress_photos`` table: insert keyed by ``photo_id`` (one row
per photo — multiple per ``(user_key, log_date, tag_id)`` are allowed),
metadata listing across a date range, a metadata fetch that returns the row's
``storage_key_prefix`` (the caller builds the object key and streams the bytes
from the object store), and deletion by photo id (which surfaces the deleted
row's prefix so the caller can clean up the backing objects).

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

    Includes ``storage_key_prefix`` so callers can locate the backing objects
    in the photo store.

    **Outputs:**
    - tuple[Any, ...]: Ordered SQLAlchemy column elements ready for ``select()``:
      ``id``, ``user_key``, ``log_date``, ``tag_id``, ``photo_mime``, ``bytes``,
      ``sha256``, ``storage_key_prefix``, ``created_at``, ``updated_at``.
    """
    return (
        progress_photos.c.id,
        progress_photos.c.user_key,
        progress_photos.c.log_date,
        progress_photos.c.tag_id,
        progress_photos.c.photo_mime,
        progress_photos.c.bytes,
        progress_photos.c.sha256,
        progress_photos.c.storage_key_prefix,
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
        photo_mime: str,
        bytes_: int,
        sha256: str,
        now: DateTimeValue,
        photo_id: UUID,
        storage_key_prefix: str,
        idempotency_key: UUID | None = None,
    ) -> dict[str, Any]:
        """Insert a new progress-photo row, returning its summary projection.

        Unlike the previous slot-based model there is no per-day uniqueness:
        a user may persist many photos for the same ``(log_date, tag_id)``.
        When ``idempotency_key`` is supplied, the row is deduped against the
        partial unique index ``uq_progress_photos_user_idem`` so retries by
        the offline upload queue return the previously-inserted row instead
        of creating a duplicate. On that conflict path the returned row is the
        *existing* one, which may carry a different ``id`` than ``photo_id``.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - log_date (DateValue): Calendar date the photo belongs to.
        - tag_id (UUID): FK into ``progress_photo_tags``.
        - photo_mime (str): MIME type for the stored image.
        - bytes_ (int): Byte length of the display encoding for metadata reporting.
        - sha256 (str): Hex digest of the photo content for client cache keys.
        - now (DateTimeValue): Timestamp for ``created_at``/``updated_at``.
        - photo_id (UUID): Pre-generated primary key. The service generates this
          up front so the object keys can embed it before the row exists.
        - storage_key_prefix (str): Object-store prefix under which the photo's
          archive/display/thumb bytes live.
        - idempotency_key (UUID | None): Optional client-supplied dedup key.
          When set, a second call with the same ``(user_key, idempotency_key)``
          returns the existing row instead of inserting a duplicate.

        **Outputs:**
        - dict[str, Any]: Summary row of the inserted (or pre-existing) record.
          Its ``id`` differs from ``photo_id`` when an idempotent conflict
          returned the original row.
        """
        values: dict[str, Any] = {
            "id": photo_id,
            "user_key": user_key,
            "log_date": log_date,
            "tag_id": tag_id,
            "photo_mime": photo_mime,
            "bytes": bytes_,
            "sha256": sha256,
            "storage_key_prefix": storage_key_prefix,
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

    async def get_photo(self, *, photo_id: UUID, user_key: str) -> dict[str, Any] | None:
        """Fetch a photo's cache headers and object-store prefix.

        The photo's bytes live in the object store under
        ``storage_key_prefix``; the caller builds the per-variant object key
        from that prefix and streams the bytes from the store.

        **Inputs:**
        - photo_id (UUID): Photo primary key.
        - user_key (str): Owning user's scoping key.

        **Outputs:**
        - dict[str, Any] | None: Mapping with ``photo_mime``, ``sha256``,
          ``updated_at``, and ``storage_key_prefix`` when a row exists; ``None``
          otherwise.
        """
        stmt = (
            select(
                progress_photos.c.photo_mime,
                progress_photos.c.sha256,
                progress_photos.c.updated_at,
                progress_photos.c.storage_key_prefix,
            )
            .where(progress_photos.c.id == photo_id)
            .where(progress_photos.c.user_key == user_key)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def delete(self, *, photo_id: UUID, user_key: str) -> dict[str, Any] | None:
        """Remove a progress-photo row by id (scoped to its owner).

        Returns the deleted row's ``storage_key_prefix`` so the caller can
        clean up the backing objects in the photo store.

        **Inputs:**
        - photo_id (UUID): Photo primary key.
        - user_key (str): Owning user's scoping key.

        **Outputs:**
        - dict[str, Any] | None: Mapping with the deleted row's ``id`` and
          ``storage_key_prefix`` when a row was removed; ``None`` when no
          matching row existed.
        """
        stmt = (
            delete(progress_photos)
            .where(progress_photos.c.id == photo_id)
            .where(progress_photos.c.user_key == user_key)
            .returning(progress_photos.c.id, progress_photos.c.storage_key_prefix)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None
