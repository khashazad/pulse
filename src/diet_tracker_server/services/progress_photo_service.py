"""Business logic for progress photos: validation and pipeline orchestration.

Wraps :func:`process_photo` with date/slot validation and maps the
pipeline's :class:`PhotoTooLargeError` / :class:`UnsupportedImageError` to
HTTP 413/415. Exposes :func:`upsert_one` (single-slot upload) and
:func:`upsert_batch` (whole-day multi-slot upload sharing one timestamp),
both of which compute the sha256 of the processed full image and hand the
result to :class:`ProgressPhotoRepository`. Caller controls the transaction
boundary on the repository.
"""

from __future__ import annotations

import hashlib
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from datetime import timezone as TimezoneValue
from typing import Any

from fastapi import HTTPException, status

from diet_tracker_server.models.progress_photo import ALLOWED_SLOTS
from diet_tracker_server.repositories.progress_photo import ProgressPhotoRepository
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


def _validate_slot(slot: str) -> None:
    """Reject slots outside the canonical ``ALLOWED_SLOTS`` set.

    **Inputs:**
    - slot (str): Caller-supplied slot identifier.

    **Exceptions:**
    - fastapi.HTTPException: Raised with 400 when ``slot`` is not in
      ``ALLOWED_SLOTS``.
    """
    if slot not in ALLOWED_SLOTS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"slot must be one of {ALLOWED_SLOTS}",
        )


def _process_or_raise(raw: bytes, *, label: str = "") -> tuple[bytes, bytes, str]:
    """Run :func:`process_photo`, mapping pipeline errors to HTTP responses.

    **Inputs:**
    - raw (bytes): Raw upload bytes.
    - label (str): Optional prefix prepended to the error detail (used by
      batch uploads to identify which slot failed).

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
        detail = f"{label}: {exc}" if label else str(exc)
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail=detail
        ) from exc
    except UnsupportedImageError as exc:
        detail = f"{label}: {exc}" if label else str(exc)
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, detail=detail
        ) from exc


async def upsert_one(
    *,
    repo: ProgressPhotoRepository,
    user_key: str,
    log_date: DateValue,
    slot: str,
    raw: bytes,
) -> dict[str, Any]:
    """Validate, process, and upsert a single progress photo into one slot.

    Computes the sha256 of the processed full JPEG and stamps an
    ``updated_at`` timestamp at call time.

    **Inputs:**
    - repo (ProgressPhotoRepository): Repository bound to the active session.
    - user_key (str): Owning user's scoping key.
    - log_date (DateValue): Date the photo is filed under.
    - slot (str): Target slot (must be in ``ALLOWED_SLOTS``).
    - raw (bytes): Raw upload bytes.

    **Outputs:**
    - dict[str, Any]: The upserted progress-photo row.

    **Exceptions:**
    - fastapi.HTTPException: Raised with 400 for future dates or invalid
      slots, 413 when the payload exceeds the byte cap, or 415 when the
      image cannot be decoded.
    - sqlalchemy.exc.SQLAlchemyError: Raised when the repository upsert
      fails.
    """
    _validate_date(log_date)
    _validate_slot(slot)
    full, thumb, mime = _process_or_raise(raw)
    sha = hashlib.sha256(full).hexdigest()
    return await repo.upsert(
        user_key=user_key,
        log_date=log_date,
        slot=slot,
        photo=full,
        photo_thumb=thumb,
        photo_mime=mime,
        bytes_=len(full),
        sha256=sha,
        now=DateTimeValue.now(tz=TimezoneValue.utc),
    )


async def upsert_batch(
    *,
    repo: ProgressPhotoRepository,
    user_key: str,
    log_date: DateValue,
    assignments: dict[str, bytes],
) -> list[dict[str, Any]]:
    """Process and upsert all provided slots for one day, sharing one timestamp.

    Validates the date, every slot, then runs the full image pipeline on
    each payload before any database write so a single bad photo aborts the
    whole batch without partial writes. The caller controls transaction
    scope.

    **Inputs:**
    - repo (ProgressPhotoRepository): Repository bound to the active session.
    - user_key (str): Owning user's scoping key.
    - log_date (DateValue): Date the photos are filed under.
    - assignments (dict[str, bytes]): Map of slot name to raw upload bytes.

    **Outputs:**
    - list[dict[str, Any]]: The upserted progress-photo rows, in
      ``assignments`` iteration order.

    **Exceptions:**
    - fastapi.HTTPException: Raised with 400 for future dates, empty
      ``assignments``, or invalid slots; 413 when any payload exceeds the
      byte cap; 415 when any image cannot be decoded.
    - sqlalchemy.exc.SQLAlchemyError: Raised when any repository upsert
      fails.
    """
    _validate_date(log_date)
    if not assignments:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="no photos provided"
        )
    processed: list[dict[str, Any]] = []
    for slot in assignments:
        _validate_slot(slot)
    for slot, raw in assignments.items():
        full, thumb, mime = _process_or_raise(raw, label=slot)
        processed.append(
            {
                "slot": slot,
                "full": full,
                "thumb": thumb,
                "mime": mime,
                "sha256": hashlib.sha256(full).hexdigest(),
            }
        )
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    out: list[dict[str, Any]] = []
    for item in processed:
        row = await repo.upsert(
            user_key=user_key,
            log_date=log_date,
            slot=item["slot"],
            photo=item["full"],
            photo_thumb=item["thumb"],
            photo_mime=item["mime"],
            bytes_=len(item["full"]),
            sha256=item["sha256"],
            now=now,
        )
        out.append(row)
    return out
