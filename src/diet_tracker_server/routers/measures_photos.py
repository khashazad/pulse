"""Endpoints for /measures/photos — list, single fetch, single PUT, batch PUT, delete."""

from __future__ import annotations

from datetime import date as DateValue
from typing import Literal

from fastapi import (
    APIRouter,
    Depends,
    File,
    HTTPException,
    Query,
    Request,
    Response,
    UploadFile,
    status,
)
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.auth import require_session
from diet_tracker_server.db import get_session_dependency, transaction
from diet_tracker_server.models.progress_photo import ALLOWED_SLOTS
from diet_tracker_server.repositories.progress_photo import ProgressPhotoRepository
from diet_tracker_server.services.progress_photo_service import (
    MAX_UPLOAD_BYTES,
    upsert_batch,
    upsert_one,
)

router = APIRouter(prefix="/measures", dependencies=[Depends(require_session)])

_UPLOAD_CHUNK_BYTES = 64 * 1024


async def _read_capped(file: UploadFile, max_bytes: int) -> bytes:
    """Stream an UploadFile, aborting once cumulative bytes exceed max_bytes."""
    buffer = bytearray()
    while True:
        chunk = await file.read(_UPLOAD_CHUNK_BYTES)
        if not chunk:
            break
        if len(buffer) + len(chunk) > max_bytes:
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail=f"upload exceeds {max_bytes}-byte cap",
            )
        buffer.extend(chunk)
    return bytes(buffer)


def _row_to_metadata(row: dict) -> dict:
    log_date = row["log_date"]
    return {
        "date": log_date.isoformat() if hasattr(log_date, "isoformat") else log_date,
        "slot": row["slot"],
        "mime": row["photo_mime"],
        "bytes": row["bytes"],
        "sha256": row["sha256"],
        "updated_at": row["updated_at"],
    }


@router.get("/photos")
async def list_photos(
    request: Request,
    frm: DateValue = Query(..., alias="from"),
    to: DateValue = Query(...),
    session: AsyncSession = Depends(get_session_dependency),
) -> list[dict]:
    user_key = request.state.user_key
    repo = ProgressPhotoRepository(session)
    rows = await repo.list_metadata(user_key=user_key, frm=frm, to=to)
    return [_row_to_metadata(r) for r in rows]


@router.get("/photos/{log_date}/{slot}")
async def get_photo(
    request: Request,
    log_date: DateValue,
    slot: str,
    size: Literal["full", "thumb"] = "full",
    session: AsyncSession = Depends(get_session_dependency),
) -> Response:
    if slot not in ALLOWED_SLOTS:
        raise HTTPException(status_code=400, detail="invalid slot")
    user_key = request.state.user_key
    repo = ProgressPhotoRepository(session)
    row = await repo.get_photo(
        user_key=user_key,
        log_date=log_date,
        slot=slot,
        thumb=(size == "thumb"),
    )
    if not row:
        raise HTTPException(status_code=404, detail="not found")
    headers = {
        "Cache-Control": "private, max-age=31536000, immutable",
        "ETag": f'"{row["sha256"]}"',
    }
    return Response(
        content=bytes(row["photo"]),
        media_type=row["photo_mime"],
        headers=headers,
    )


@router.put("/photos/{log_date}/{slot}")
async def put_photo(
    request: Request,
    log_date: DateValue,
    slot: str,
    file: UploadFile = File(...),
    session: AsyncSession = Depends(get_session_dependency),
) -> dict:
    user_key = request.state.user_key
    raw = await _read_capped(file, MAX_UPLOAD_BYTES)
    repo = ProgressPhotoRepository(session)
    async with transaction(session):
        row = await upsert_one(
            repo=repo,
            user_key=user_key,
            log_date=log_date,
            slot=slot,
            raw=raw,
        )
    return _row_to_metadata(row)


@router.put("/photos/{log_date}")
async def put_photos_batch(
    request: Request,
    log_date: DateValue,
    session: AsyncSession = Depends(get_session_dependency),
) -> list[dict]:
    """Upsert multiple slots in one multipart request.

    Each named file field maps to a slot (`front`, `left`, `right`, `back`).
    All upserts run in a single transaction.
    """
    form = await request.form()
    assignments: dict[str, bytes] = {}
    for key in form:
        if key not in ALLOWED_SLOTS:
            raise HTTPException(
                status_code=400, detail=f"unknown slot field: {key}"
            )
        upload = form[key]
        if not hasattr(upload, "read"):
            raise HTTPException(
                status_code=400, detail=f"field {key} must be a file"
            )
        assignments[key] = await _read_capped(upload, MAX_UPLOAD_BYTES)
    user_key = request.state.user_key
    repo = ProgressPhotoRepository(session)
    async with transaction(session):
        rows = await upsert_batch(
            repo=repo,
            user_key=user_key,
            log_date=log_date,
            assignments=assignments,
        )
    return [_row_to_metadata(r) for r in rows]


@router.delete("/photos/{log_date}/{slot}", status_code=204)
async def delete_photo(
    request: Request,
    log_date: DateValue,
    slot: str,
    session: AsyncSession = Depends(get_session_dependency),
) -> Response:
    if slot not in ALLOWED_SLOTS:
        raise HTTPException(status_code=400, detail="invalid slot")
    user_key = request.state.user_key
    repo = ProgressPhotoRepository(session)
    async with transaction(session):
        ok = await repo.delete(user_key=user_key, log_date=log_date, slot=slot)
    if not ok:
        raise HTTPException(status_code=404, detail="not found")
    return Response(status_code=204)
