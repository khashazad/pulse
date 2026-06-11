"""HTTP endpoints for progress (body-measurement) photos.

Exposes the ``/measures`` router covering ``/photos`` list, single-photo
fetch (``thumb``/``full``/``archive``), tagged single-photo upload, and
photo-id-based delete. Each photo is identified by its ``photo_id`` UUID; many
photos may share a ``(log_date, tag_id)`` since the legacy four-slot uniqueness
has been removed. Photo bytes live in the object store, streamed via the row's
``storage_key_prefix`` (NOT NULL since the object-store cutover completed).
Uploads are streamed with a hard byte cap; transcoding and object writes live
in :mod:`services.progress_photo_service`.
"""

from __future__ import annotations

import logging
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

from pulse_server.auth import require_session
from pulse_server.db import get_session_dependency, transaction
from pulse_server.models.progress_photo import ProgressPhotoMetadata
from pulse_server.photo_store import PhotoStore, get_photo_object, get_photo_store
from pulse_server.repositories.progress_photo import ProgressPhotoRepository
from pulse_server.repositories.progress_photo_tag import (
    ProgressPhotoTagRepository,
)
from pulse_server.routers.uploads import read_capped
from pulse_server.services.image_processing import PhotoTooLargeError
from pulse_server.services.progress_photo_service import (
    MAX_UPLOAD_BYTES,
    VARIANT_OBJECTS,
    delete_photo_objects,
    insert_one,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/measures", dependencies=[Depends(require_session)])


def _row_to_metadata(row: dict) -> ProgressPhotoMetadata:
    """Project a raw ``progress_photos`` row into its typed metadata DTO.

    **Inputs:**
    - row (dict): Column→value mapping returned by :class:`ProgressPhotoRepository`.

    **Outputs:**
    - ProgressPhotoMetadata: Typed metadata model whose serialized JSON is
      byte-identical to the prior dict payload (``id``, ``date``, ``tag_id``,
      ``mime``, ``bytes``, ``sha256``, ``updated_at``).
    """
    return ProgressPhotoMetadata(
        id=row["id"],
        date=row["log_date"],
        tag_id=row["tag_id"],
        mime=row["photo_mime"],
        bytes=row["bytes"],
        sha256=row["sha256"],
        updated_at=row["updated_at"],
    )


@router.get("/photos", response_model=list[ProgressPhotoMetadata])
async def list_photos(
    request: Request,
    frm: DateValue = Query(..., alias="from"),
    to: DateValue = Query(...),
    session: AsyncSession = Depends(get_session_dependency),
) -> list[ProgressPhotoMetadata]:
    """List metadata for every progress photo within an inclusive date range.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - frm (date): Inclusive start date (query alias ``from``).
    - to (date): Inclusive end date.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - list[ProgressPhotoMetadata]: One metadata model per stored photo.
    """
    user_key = request.state.user_key
    repo = ProgressPhotoRepository(session)
    rows = await repo.list_metadata(user_key=user_key, frm=frm, to=to)
    return [_row_to_metadata(r) for r in rows]


@router.get("/photos/{photo_id}")
async def get_photo(
    request: Request,
    photo_id: UUID,
    size: Literal["full", "thumb", "archive"] = "full",
    session: AsyncSession = Depends(get_session_dependency),
    store: PhotoStore = Depends(get_photo_store),
) -> Response:
    """Return raw progress-photo bytes for one ``photo_id``.

    The bytes are streamed from the object store using the row's
    ``storage_key_prefix`` and the ``size``→object mapping. The ``archive``
    variant is the high-resolution preservation copy (pre-cutover rows received
    an archive object during migration, so every row has all three variants).
    Sends a strong ``ETag`` derived from the stored sha256 and a 1-year
    immutable cache header.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - photo_id (UUID): Photo primary key.
    - size (Literal["full","thumb","archive"]): Variant to return; default ``"full"``.
    - session (AsyncSession): DB session dependency.
    - store (PhotoStore): Photo object store dependency.

    **Outputs:**
    - Response: Image bytes with the stored MIME type plus caching headers.

    **Exceptions:**
    - HTTPException(404): Raised when no photo exists with that id, or when the
      row's object is missing from the store (data inconsistency: row present,
      object absent — logged at WARNING before raising).
    """
    user_key = request.state.user_key
    repo = ProgressPhotoRepository(session)
    row = await repo.get_photo(photo_id=photo_id, user_key=user_key)
    if not row:
        raise HTTPException(status_code=404, detail="not found")
    key = f"{row['storage_key_prefix']}/{VARIANT_OBJECTS[size]}"
    fetched = await get_photo_object(store, key)
    if fetched is None:
        # The key embeds request-derived parts (photo id in the prefix);
        # strip newlines so a crafted value can't forge extra log lines
        # (CodeQL py/log-injection).
        logger.warning(
            "data inconsistency: photo row exists but object %s is missing from store",
            key.replace("\r\n", "").replace("\n", ""),
        )
        raise HTTPException(status_code=404, detail="not found")
    headers = {
        "Cache-Control": "private, max-age=31536000, immutable",
        "ETag": f'"{row["sha256"]}"',
    }
    return Response(content=fetched, media_type=row["photo_mime"], headers=headers)


@router.post("/photos", status_code=201, response_model=ProgressPhotoMetadata)
async def create_photo(
    request: Request,
    log_date: DateValue = Form(..., alias="log_date"),
    tag_id: UUID = Form(..., alias="tag_id"),
    idempotency_key: UUID | None = Form(default=None, alias="idempotency_key"),
    file: UploadFile = File(...),
    session: AsyncSession = Depends(get_session_dependency),
    store: PhotoStore = Depends(get_photo_store),
) -> ProgressPhotoMetadata:
    """Insert a new progress photo tagged with ``tag_id`` for ``log_date``.

    Streams the upload under :data:`MAX_UPLOAD_BYTES`, hands off to
    :func:`insert_one` for image validation/transcoding and persistence.
    Multiple photos may share the same ``(log_date, tag_id)``. When the
    client supplies an ``idempotency_key`` (a stable UUID it reuses across
    retries of the same logical upload), a duplicate POST returns the
    previously-inserted row instead of creating another one.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - log_date (date): Date the photo was taken (multipart form field).
    - tag_id (UUID): Tag to attach (multipart form field).
    - idempotency_key (UUID | None): Optional client-supplied dedup key.
    - file (UploadFile): Multipart image upload.
    - session (AsyncSession): DB session dependency.
    - store (PhotoStore): Photo object store dependency.

    **Outputs:**
    - ProgressPhotoMetadata: Metadata for the inserted (or pre-existing) row.

    **Exceptions:**
    - HTTPException(400): Raised for future dates.
    - HTTPException(404): Raised when ``tag_id`` does not belong to the user.
    - HTTPException(413): Raised when the upload exceeds the byte cap.
    - HTTPException(415): Raised when the image is unsupported.
    """
    user_key = request.state.user_key
    try:
        raw = await read_capped(file, MAX_UPLOAD_BYTES)
    except PhotoTooLargeError as exc:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail=str(exc)
        ) from exc
    repo = ProgressPhotoRepository(session)
    tag_repo = ProgressPhotoTagRepository(session)
    async with transaction(session):
        row = await insert_one(
            repo=repo,
            tag_repo=tag_repo,
            store=store,
            user_key=user_key,
            log_date=log_date,
            tag_id=tag_id,
            raw=raw,
            idempotency_key=idempotency_key,
        )
    return _row_to_metadata(row)


@router.delete("/photos/{photo_id}", status_code=204)
async def delete_photo(
    request: Request,
    photo_id: UUID,
    session: AsyncSession = Depends(get_session_dependency),
    store: PhotoStore = Depends(get_photo_store),
) -> Response:
    """Delete a progress photo by id and return HTTP 204.

    The row is removed inside the transaction; its object-store copies (located
    via the deleted row's NOT NULL ``storage_key_prefix``) are deleted **after**
    commit. A failed object delete only logs and orphans the objects
    (best-effort cleanup) rather than rolling back the committed row — the row
    delete is the source of truth.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - photo_id (UUID): Photo primary key.
    - session (AsyncSession): DB session dependency.
    - store (PhotoStore): Photo object store dependency.

    **Outputs:**
    - Response: Empty 204 response.

    **Exceptions:**
    - HTTPException(404): Raised when no photo exists with that id.
    """
    user_key = request.state.user_key
    repo = ProgressPhotoRepository(session)
    async with transaction(session):
        deleted = await repo.delete(photo_id=photo_id, user_key=user_key)
    if deleted is None:
        raise HTTPException(status_code=404, detail="not found")
    await delete_photo_objects(store, deleted["storage_key_prefix"])
    return Response(status_code=204)
