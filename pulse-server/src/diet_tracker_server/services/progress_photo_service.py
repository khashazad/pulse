"""Business logic for progress photos: validation + pipeline orchestration."""

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
    today = DateTimeValue.now(tz=TimezoneValue.utc).date()
    if log_date > today:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="future date not allowed",
        )


def _validate_slot(slot: str) -> None:
    if slot not in ALLOWED_SLOTS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"slot must be one of {ALLOWED_SLOTS}",
        )


def _process_or_raise(raw: bytes, *, label: str = "") -> tuple[bytes, bytes, str]:
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
    """Process all provided slots in a single transaction."""
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
