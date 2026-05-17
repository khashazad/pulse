"""HTTP endpoints for progress (body-measurement) photos.

Exposes the ``/measures`` router covering ``/photos`` list, single-photo
fetch (``thumb``/``full``), single-slot PUT, multi-slot batch PUT, and slot
delete. Each photo is identified by ``(log_date, slot)`` where ``slot`` is one
of :data:`ALLOWED_SLOTS` (``front``, ``left``, ``right``, ``back``). Uploads
are streamed with a hard byte cap; storage and transcoding live in
:mod:`services.progress_photo_service`.
"""

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
    """Stream an UploadFile in 64 KiB chunks, aborting once cumulative bytes exceed ``max_bytes``.

    **Inputs:**
    - file (UploadFile): Streaming multipart file handle.
    - max_bytes (int): Inclusive cap on total payload size in bytes.

    **Outputs:**
    - bytes: The fully buffered payload, length ≤ ``max_bytes``.

    **Exceptions:**
    - HTTPException(413): Raised once the running total would exceed ``max_bytes``.
    """
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
    """Project a raw ``progress_photos`` row into the public metadata payload.

    **Inputs:**
    - row (dict): Column→value mapping returned by :class:`ProgressPhotoRepository`.

    **Outputs:**
    - dict: ``{date, slot, mime, bytes, sha256, updated_at}`` with ``date`` as ISO string.
    """
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
    """List metadata for every progress photo within an inclusive date range.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - frm (date): Inclusive start date (query alias ``from``).
    - to (date): Inclusive end date.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - list[dict]: One metadata mapping per stored ``(date, slot)`` pair.
    """
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
    """Return raw progress-photo bytes for one ``(log_date, slot)`` pair.

    Sends a strong ``ETag`` derived from the stored sha256 and a 1-year
    immutable cache header.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - log_date (date): Date the photo was taken.
    - slot (str): One of :data:`ALLOWED_SLOTS`.
    - size (Literal["full","thumb"]): Variant to return; default ``"full"``.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - Response: Image bytes with the stored MIME type plus caching headers.

    **Exceptions:**
    - HTTPException(400): Raised when ``slot`` is not in :data:`ALLOWED_SLOTS`.
    - HTTPException(404): Raised when no photo exists for that ``(date, slot)``.
    """
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
    """Upsert a single progress photo at ``(log_date, slot)``.

    Streams the upload under :data:`MAX_UPLOAD_BYTES`, hands off to
    :func:`upsert_one` for image validation/transcoding and persistence.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - log_date (date): Date the photo was taken.
    - slot (str): One of :data:`ALLOWED_SLOTS`.
    - file (UploadFile): Multipart image upload.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - dict: Metadata for the upserted row (date, slot, mime, bytes, sha256, updated_at).

    **Exceptions:**
    - HTTPException(413): Raised when the upload exceeds the byte cap.
    - HTTPException(415): Raised by the service layer when the image is unsupported.
    - HTTPException(400): Raised by the service layer when ``slot`` is invalid.
    """
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
    """Upsert multiple slots for the same date in a single multipart request.

    Each named file field maps to a slot (``front``, ``left``, ``right``,
    ``back``). All upserts run inside one transaction so the batch is
    all-or-nothing.

    **Inputs:**
    - request (Request): Active request; reads the multipart form directly.
    - log_date (date): Date the photos were taken.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - list[dict]: Metadata for every upserted row.

    **Exceptions:**
    - HTTPException(400): Raised when a form field uses an unknown slot name or is not a file.
    - HTTPException(413): Raised when any single upload exceeds the byte cap.
    - HTTPException(415): Raised by the service layer when an image is unsupported.
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
    """Delete a progress photo at ``(log_date, slot)`` and return HTTP 204.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - log_date (date): Date the photo was taken.
    - slot (str): One of :data:`ALLOWED_SLOTS`.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - Response: Empty 204 response.

    **Exceptions:**
    - HTTPException(400): Raised when ``slot`` is not in :data:`ALLOWED_SLOTS`.
    - HTTPException(404): Raised when no photo exists for that ``(date, slot)``.
    """
    if slot not in ALLOWED_SLOTS:
        raise HTTPException(status_code=400, detail="invalid slot")
    user_key = request.state.user_key
    repo = ProgressPhotoRepository(session)
    async with transaction(session):
        ok = await repo.delete(user_key=user_key, log_date=log_date, slot=slot)
    if not ok:
        raise HTTPException(status_code=404, detail="not found")
    return Response(status_code=204)
