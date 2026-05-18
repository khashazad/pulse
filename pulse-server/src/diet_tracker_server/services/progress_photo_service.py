"""Business logic for progress photos: validation and pipeline orchestration.

Wraps :func:`process_photo` with date and tag validation and maps the
pipeline's :class:`PhotoTooLargeError` / :class:`UnsupportedImageError` to
HTTP 413/415. Exposes :func:`insert_one`, which inserts a single tagged
photo row, computing the sha256 of the processed full image. Caller controls
the transaction boundary on the repository.
"""

from __future__ import annotations

import hashlib
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from datetime import timezone as TimezoneValue
from typing import Any
from uuid import UUID

from fastapi import HTTPException, status

from diet_tracker_server.repositories.progress_photo import ProgressPhotoRepository
from diet_tracker_server.repositories.progress_photo_tag import (
    ProgressPhotoTagRepository,
)
from diet_tracker_server.services.image_processing import (
    PhotoTooLargeError,
    UnsupportedImageError,
    process_photo,
)

MAX_UPLOAD_BYTES = 10 * 1024 * 1024  # 10 MB


def _validate_date(log_date: DateValue) -> None:
    """Reject future-dated progress photos.

    **Inputs:**
    - log_date (DateValue): Date the photo is being filed under.

    **Exceptions:**
    - fastapi.HTTPException: Raised with 400 when ``log_date`` is later than
      today (UTC).
    """
    today = DateTimeValue.now(tz=TimezoneValue.utc).date()
    if log_date > today:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="future date not allowed",
        )


def _process_or_raise(raw: bytes) -> tuple[bytes, bytes, str]:
    """Run :func:`process_photo`, mapping pipeline errors to HTTP responses.

    **Inputs:**
    - raw (bytes): Raw upload bytes.

    **Outputs:**
    - tuple[bytes, bytes, str]: ``(full_jpeg, thumb_jpeg, mime)``.

    **Exceptions:**
    - fastapi.HTTPException: Raised with 413 when the payload exceeds
      ``MAX_UPLOAD_BYTES``, or with 415 when the image is undecodable or
      exceeds the pixel cap.
    """
    try:
        return process_photo(raw, max_bytes=MAX_UPLOAD_BYTES)
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
    user_key: str,
    log_date: DateValue,
    tag_id: UUID,
    raw: bytes,
    idempotency_key: UUID | None = None,
) -> dict[str, Any]:
    """Validate, process, and insert a single tagged progress photo.

    Computes the sha256 of the processed full JPEG and stamps an
    ``updated_at`` timestamp at call time. Verifies the tag belongs to the
    user before any image processing happens so a bad ``tag_id`` short-
    circuits without spending CPU on Pillow.

    **Inputs:**
    - repo (ProgressPhotoRepository): Repository bound to the active session.
    - tag_repo (ProgressPhotoTagRepository): Repository bound to the same session.
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
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="tag not found"
        )
    full, thumb, mime = _process_or_raise(raw)
    sha = hashlib.sha256(full).hexdigest()
    return await repo.insert(
        user_key=user_key,
        log_date=log_date,
        tag_id=tag_id,
        photo=full,
        photo_thumb=thumb,
        photo_mime=mime,
        bytes_=len(full),
        sha256=sha,
        now=DateTimeValue.now(tz=TimezoneValue.utc),
        idempotency_key=idempotency_key,
    )
