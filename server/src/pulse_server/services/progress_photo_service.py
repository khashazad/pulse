"""Business logic for progress photos: validation and pipeline orchestration.

Wraps :func:`process_progress_photo` with date and tag validation and maps the
pipeline's :class:`PhotoTooLargeError` / :class:`UnsupportedImageError` to
HTTP 413/415. Exposes :func:`insert_one`, which processes a single tagged
photo into archive/display/thumb encodings, writes those three objects to the
photo store under ``progress/{user_key}/{photo_id}/``, then inserts the
metadata row (blobs are no longer written to Postgres). Also exposes
:func:`object_keys` and :func:`delete_photo_objects` for store cleanup. Caller
controls the transaction boundary on the repository.
"""

from __future__ import annotations

import hashlib
import logging
from datetime import UTC
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID, uuid4

from fastapi import HTTPException, status

from pulse_server.photo_store import PhotoStore
from pulse_server.repositories.progress_photo import ProgressPhotoRepository
from pulse_server.repositories.progress_photo_tag import (
    ProgressPhotoTagRepository,
)
from pulse_server.services.image_processing import (
    PhotoTooLargeError,
    ProcessedProgressPhoto,
    UnsupportedImageError,
    process_progress_photo,
)

logger = logging.getLogger(__name__)

MAX_UPLOAD_BYTES = 10 * 1024 * 1024  # 10 MB

# Object names under each photo's storage prefix; "full" is the wire-facing
# size param, "display.jpg" the stored object.
VARIANT_OBJECTS = {"full": "display.jpg", "thumb": "thumb.jpg", "archive": "archive.jpg"}


def object_keys(prefix: str) -> list[str]:
    """Return every object key stored under a photo's prefix.

    **Inputs:**
    - prefix (str): The photo's ``storage_key_prefix``.

    **Outputs:**
    - list[str]: Keys for the archive, display, and thumb objects.
    """
    return [f"{prefix}/{name}" for name in VARIANT_OBJECTS.values()]


async def delete_photo_objects(store: PhotoStore, prefix: str) -> None:
    """Best-effort delete of a photo's three objects; never raises.

    Used both for cleanup when a DB insert fails after upload and after a
    photo row is deleted. Failures are logged and swallowed — at worst an
    orphaned object lingers in the bucket, which is preferable to failing the
    user-facing request.

    **Inputs:**
    - store (PhotoStore): The photo object store.
    - prefix (str): The photo's ``storage_key_prefix``.

    **Outputs:**
    - None.
    """
    try:
        await store.delete_async(object_keys(prefix))
    except Exception:  # cleanup must never mask the caller's outcome
        logger.warning("failed to delete photo objects under %s", prefix, exc_info=True)


def _validate_date(log_date: DateValue) -> None:
    """Reject future-dated progress photos.

    **Inputs:**
    - log_date (DateValue): Date the photo is being filed under.

    **Exceptions:**
    - fastapi.HTTPException: Raised with 400 when ``log_date`` is later than
      today (UTC).
    """
    today = DateTimeValue.now(tz=UTC).date()
    if log_date > today:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="future date not allowed",
        )


def _process_or_raise(raw: bytes) -> ProcessedProgressPhoto:
    """Run :func:`process_progress_photo`, mapping pipeline errors to HTTP responses.

    **Inputs:**
    - raw (bytes): Raw upload bytes.

    **Outputs:**
    - ProcessedProgressPhoto: The archive/display/thumb encodings plus MIME type.

    **Exceptions:**
    - fastapi.HTTPException: Raised with 413 when the payload exceeds
      ``MAX_UPLOAD_BYTES``, or with 415 when the image is undecodable or
      exceeds the pixel cap.
    """
    try:
        return process_progress_photo(raw, max_bytes=MAX_UPLOAD_BYTES)
    except PhotoTooLargeError as exc:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail=str(exc)
        ) from exc
    except UnsupportedImageError as exc:
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, detail=str(exc)
        ) from exc


async def insert_one(
    *,
    repo: ProgressPhotoRepository,
    tag_repo: ProgressPhotoTagRepository,
    store: PhotoStore,
    user_key: str,
    log_date: DateValue,
    tag_id: UUID,
    raw: bytes,
    idempotency_key: UUID | None = None,
) -> dict[str, Any]:
    """Validate, process, upload, and insert a single tagged progress photo.

    Verifies the tag belongs to the user before any image processing so a bad
    ``tag_id`` short-circuits without spending CPU on Pillow. Pre-generates the
    photo id, then uploads the archive/display/thumb JPEGs to the photo store
    under ``progress/{user_key}/{photo_id}/`` before inserting the metadata row
    — the photo bytes are no longer written to Postgres. The ``sha256`` and
    ``bytes`` recorded describe the **display** encoding, preserving ETag
    continuity with the pre-cutover full image the client cached against.

    The three uploads and the DB insert run inside a single ``try`` so any
    failure — a partial upload (2nd/3rd ``put_async`` raising after the 1st
    succeeded) or the insert itself — triggers a best-effort cleanup of every
    object under the prefix before re-raising; no path can orphan earlier
    objects. On an idempotent replay the conflict path returns the original row
    (with a different ``id`` than the freshly-generated one), so the
    just-uploaded objects under the new prefix are unreferenced and likewise
    removed.

    **Inputs:**
    - repo (ProgressPhotoRepository): Repository bound to the active session.
    - tag_repo (ProgressPhotoTagRepository): Repository bound to the same session.
    - store (PhotoStore): Photo object store the three encodings are written to.
    - user_key (str): Owning user's scoping key.
    - log_date (DateValue): Date the photo is filed under.
    - tag_id (UUID): Tag to attach to the photo (must belong to ``user_key``).
    - raw (bytes): Raw upload bytes.
    - idempotency_key (UUID | None): Optional client-supplied dedup key; a
      second call with the same ``(user_key, idempotency_key)`` returns the
      previously-inserted row instead of creating a duplicate.

    **Outputs:**
    - dict[str, Any]: The inserted (or pre-existing) progress-photo row.

    **Exceptions:**
    - fastapi.HTTPException: Raised with 400 for future dates, 404 when
      ``tag_id`` is unknown, 413 when the payload exceeds the byte cap, or
      415 when the image cannot be decoded.
    """
    _validate_date(log_date)
    tag = await tag_repo.get_by_id(tag_id=tag_id, user_key=user_key)
    if tag is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="tag not found")
    processed = _process_or_raise(raw)
    photo_id = uuid4()
    prefix = f"progress/{user_key}/{photo_id}"
    sha = hashlib.sha256(processed.display).hexdigest()
    try:
        await store.put_async(f"{prefix}/archive.jpg", processed.archive)
        await store.put_async(f"{prefix}/display.jpg", processed.display)
        await store.put_async(f"{prefix}/thumb.jpg", processed.thumb)
        row = await repo.insert(
            user_key=user_key,
            log_date=log_date,
            tag_id=tag_id,
            photo_id=photo_id,
            storage_key_prefix=prefix,
            photo_mime=processed.mime,
            bytes_=len(processed.display),
            sha256=sha,
            now=DateTimeValue.now(tz=UTC),
            idempotency_key=idempotency_key,
        )
    except Exception:
        await delete_photo_objects(store, prefix)
        raise
    if row["id"] != photo_id:
        # Idempotent replay: the conflict path returned the original row, so the
        # objects uploaded under the fresh prefix are unreferenced — remove them.
        await delete_photo_objects(store, prefix)
    return row
