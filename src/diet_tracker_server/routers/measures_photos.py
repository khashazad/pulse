"""HTTP endpoints for progress (body-measurement) photos.

Exposes the ``/measures`` router covering ``/photos`` list, single-photo
fetch (``thumb``/``full``), tagged single-photo upload, and photo-id-based
delete. Each photo is identified by its ``photo_id`` UUID; many photos may
share a ``(log_date, tag_id)`` since the legacy four-slot uniqueness has
been removed. Uploads are streamed with a hard byte cap; storage and
transcoding live in :mod:`services.progress_photo_service`.
"""

from __future__ import annotations

from datetime import date as DateValue
from typing import Literal
from uuid import UUID

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
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
from diet_tracker_server.repositories.progress_photo import ProgressPhotoRepository
from diet_tracker_server.repositories.progress_photo_tag import (
    ProgressPhotoTagRepository,
)
from diet_tracker_server.services.progress_photo_service import (
    MAX_UPLOAD_BYTES,
    insert_one,
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
    - dict: ``{id, date, tag_id, mime, bytes, sha256, updated_at}`` with
      ``date`` as ISO string.
    """
    log_date = row["log_date"]
    return {
        "id": str(row["id"]),
        "date": log_date.isoformat() if hasattr(log_date, "isoformat") else log_date,
        "tag_id": str(row["tag_id"]),
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
    - list[dict]: One metadata mapping per stored photo.
    """
    user_key = request.state.user_key
    repo = ProgressPhotoRepository(session)
    rows = await repo.list_metadata(user_key=user_key, frm=frm, to=to)
    return [_row_to_metadata(r) for r in rows]


@router.get("/photos/{photo_id}")
async def get_photo(
    request: Request,
    photo_id: UUID,
    size: Literal["full", "thumb"] = "full",
    session: AsyncSession = Depends(get_session_dependency),
) -> Response:
    """Return raw progress-photo bytes for one ``photo_id``.

    Sends a strong ``ETag`` derived from the stored sha256 and a 1-year
    immutable cache header.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - photo_id (UUID): Photo primary key.
    - size (Literal["full","thumb"]): Variant to return; default ``"full"``.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - Response: Image bytes with the stored MIME type plus caching headers.

    **Exceptions:**
    - HTTPException(404): Raised when no photo exists with that id.
    """
    user_key = request.state.user_key
    repo = ProgressPhotoRepository(session)
    row = await repo.get_photo(
        photo_id=photo_id,
        user_key=user_key,
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


@router.post("/photos", status_code=201)
async def create_photo(
    request: Request,
    log_date: DateValue = Form(..., alias="log_date"),
    tag_id: UUID = Form(..., alias="tag_id"),
    file: UploadFile = File(...),
    session: AsyncSession = Depends(get_session_dependency),
) -> dict:
    """Insert a new progress photo tagged with ``tag_id`` for ``log_date``.

    Streams the upload under :data:`MAX_UPLOAD_BYTES`, hands off to
    :func:`insert_one` for image validation/transcoding and persistence.
    Multiple photos may share the same ``(log_date, tag_id)``.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - log_date (date): Date the photo was taken (multipart form field).
    - tag_id (UUID): Tag to attach (multipart form field).
    - file (UploadFile): Multipart image upload.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - dict: Metadata for the inserted row.

    **Exceptions:**
    - HTTPException(400): Raised for future dates.
    - HTTPException(404): Raised when ``tag_id`` does not belong to the user.
    - HTTPException(413): Raised when the upload exceeds the byte cap.
    - HTTPException(415): Raised when the image is unsupported.
    """
    user_key = request.state.user_key
    raw = await _read_capped(file, MAX_UPLOAD_BYTES)
    repo = ProgressPhotoRepository(session)
    tag_repo = ProgressPhotoTagRepository(session)
    async with transaction(session):
        row = await insert_one(
            repo=repo,
            tag_repo=tag_repo,
            user_key=user_key,
            log_date=log_date,
            tag_id=tag_id,
            raw=raw,
        )
    return _row_to_metadata(row)


@router.delete("/photos/{photo_id}", status_code=204)
async def delete_photo(
    request: Request,
    photo_id: UUID,
    session: AsyncSession = Depends(get_session_dependency),
) -> Response:
    """Delete a progress photo by id and return HTTP 204.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - photo_id (UUID): Photo primary key.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - Response: Empty 204 response.

    **Exceptions:**
    - HTTPException(404): Raised when no photo exists with that id.
    """
    user_key = request.state.user_key
    repo = ProgressPhotoRepository(session)
    async with transaction(session):
        ok = await repo.delete(photo_id=photo_id, user_key=user_key)
    if not ok:
        raise HTTPException(status_code=404, detail="not found")
    return Response(status_code=204)
