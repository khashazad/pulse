"""HTTP endpoints for reusable food containers (jars, tupperware, etc.).

Exposes the ``/containers`` router covering full CRUD plus photo upload/fetch/
delete. Routers handle multipart parsing, byte caps, and HTTP error mapping;
image processing lives in :mod:`services.image_processing` and SQL in
:class:`ContainersRepository`.

Containers carry a tare weight and an optional photo (stored full + thumbnail
as BYTEA). Photo bytes are streamed in 64 KiB chunks and capped at 10 MiB.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, File, HTTPException, Query, Request, Response, UploadFile
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.auth import require_session
from pulse_server.config import get_settings
from pulse_server.db import get_session_dependency, transaction
from pulse_server.models import (
    ContainerCreate,
    ContainerPhotoStatus,
    ContainerResponse,
    ContainersListResponse,
    ContainerUpdate,
    container_response,
)
from pulse_server.repositories.containers import ContainersRepository
from pulse_server.routers.uploads import read_capped
from pulse_server.services.containers_service import store_photo
from pulse_server.services.image_processing import (
    PhotoTooLargeError,
    UnsupportedImageError,
)
from pulse_server.services.normalize import normalize_name

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_session)])
TZ = ZoneInfo(settings.timezone)

MAX_UPLOAD_BYTES = 10 * 1024 * 1024  # 10 MB


@router.get("/containers", response_model=ContainersListResponse)
async def list_containers(
    request: Request,
    session: AsyncSession = Depends(get_session_dependency),
) -> ContainersListResponse:
    """List every container owned by the authenticated user.

    **Inputs:**
    - request (Request): Active request; ``request.state.user_key`` is the scope.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - ContainersListResponse: Containers in repository-defined order.
    """
    user_key = request.state.user_key
    repo = ContainersRepository(session)
    rows = await repo.list_for_user(user_key)
    return ContainersListResponse(containers=[container_response(r) for r in rows])


@router.post("/containers", status_code=201, response_model=ContainerResponse)
async def create_container(
    request: Request,
    body: ContainerCreate,
    session: AsyncSession = Depends(get_session_dependency),
) -> ContainerResponse:
    """Create a new container scoped to the authenticated user.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - body (ContainerCreate): Desired ``name`` and ``tare_weight_g``.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - ContainerResponse: The newly persisted row.

    **Exceptions:**
    - HTTPException(409): Raised when the user already owns a container with that name.
    """
    user_key = request.state.user_key
    repo = ContainersRepository(session)
    now = DateTimeValue.now(tz=TZ)
    try:
        async with transaction(session):
            row = await repo.create(
                user_key=user_key,
                name=body.name,
                normalized_name=normalize_name(body.name),
                tare_weight_g=body.tare_weight_g,
                now=now,
            )
    except IntegrityError as exc:
        raise HTTPException(
            status_code=409, detail="A container with that name already exists"
        ) from exc
    return container_response(row)


@router.get("/containers/{container_id}", response_model=ContainerResponse)
async def get_container(
    request: Request,
    container_id: UUID,
    session: AsyncSession = Depends(get_session_dependency),
) -> ContainerResponse:
    """Fetch a single container by id, scoped to the authenticated user.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - container_id (UUID): Container primary key.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - ContainerResponse: The requested row.

    **Exceptions:**
    - HTTPException(404): Raised when no container with that id is owned by the user.
    """
    user_key = request.state.user_key
    repo = ContainersRepository(session)
    row = await repo.get_by_id(container_id, user_key)
    if row is None:
        raise HTTPException(status_code=404, detail="Container not found")
    return container_response(row)


@router.patch("/containers/{container_id}", response_model=ContainerResponse)
async def update_container(
    request: Request,
    container_id: UUID,
    body: ContainerUpdate,
    session: AsyncSession = Depends(get_session_dependency),
) -> ContainerResponse:
    """Partially update a container's fields (name, tare weight) for the authenticated user.

    Recomputes ``normalized_name`` server-side whenever ``name`` is provided.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - container_id (UUID): Container primary key.
    - body (ContainerUpdate): Subset of fields to overwrite.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - ContainerResponse: The updated row.

    **Exceptions:**
    - HTTPException(409): Raised when renaming would collide with another container's name.
    - HTTPException(404): Raised when no container with that id is owned by the user.
    """
    user_key = request.state.user_key
    fields = body.model_dump(exclude_unset=True)
    if "name" in fields and fields["name"] is not None:
        fields["normalized_name"] = normalize_name(fields["name"])
    repo = ContainersRepository(session)
    now = DateTimeValue.now(tz=TZ)
    try:
        async with transaction(session):
            row = await repo.update_fields(container_id, user_key, fields, now)
    except IntegrityError as exc:
        raise HTTPException(
            status_code=409, detail="A container with that name already exists"
        ) from exc
    if row is None:
        raise HTTPException(status_code=404, detail="Container not found")
    return container_response(row)


@router.delete("/containers/{container_id}", status_code=204)
async def delete_container(
    request: Request,
    container_id: UUID,
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    """Delete a container by id and return HTTP 204 on success.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - container_id (UUID): Container primary key.
    - session (AsyncSession): DB session dependency.

    **Exceptions:**
    - HTTPException(404): Raised when no container with that id is owned by the user.
    """
    user_key = request.state.user_key
    repo = ContainersRepository(session)
    async with transaction(session):
        deleted = await repo.delete(container_id, user_key)
    if not deleted:
        raise HTTPException(status_code=404, detail="Container not found")


@router.put("/containers/{container_id}/photo", response_model=ContainerPhotoStatus)
async def upload_container_photo(
    request: Request,
    container_id: UUID,
    file: UploadFile = File(...),
    session: AsyncSession = Depends(get_session_dependency),
) -> ContainerPhotoStatus:
    """Upload (replace) the photo for a container, persisting full + thumb BYTEA.

    Streams the upload with a 10 MiB cap, converts it via Pillow, and writes the
    result atomically through :class:`ContainersRepository`.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - container_id (UUID): Container primary key.
    - file (UploadFile): Multipart image upload.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - ContainerPhotoStatus: ``has_photo=True`` once the upload is stored.

    **Exceptions:**
    - HTTPException(413): Raised when the upload exceeds the 10 MiB cap.
    - HTTPException(415): Raised when the payload is not a supported/decodable image.
    - HTTPException(404): Raised when the container does not exist for this user.
    """
    user_key = request.state.user_key

    try:
        raw = await read_capped(file, MAX_UPLOAD_BYTES)
    except PhotoTooLargeError as exc:
        raise HTTPException(status_code=413, detail=str(exc)) from exc

    try:
        ok = await store_photo(
            session,
            container_id=container_id,
            user_key=user_key,
            raw=raw,
            max_bytes=MAX_UPLOAD_BYTES,
            now=DateTimeValue.now(tz=TZ),
        )
    except PhotoTooLargeError as exc:
        raise HTTPException(status_code=413, detail=str(exc)) from exc
    except UnsupportedImageError as exc:
        raise HTTPException(status_code=415, detail="Unsupported or corrupt image") from exc
    if not ok:
        raise HTTPException(status_code=404, detail="Container not found")
    return ContainerPhotoStatus(has_photo=True)


@router.delete("/containers/{container_id}/photo", status_code=204)
async def delete_container_photo(
    request: Request,
    container_id: UUID,
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    """Clear the stored photo bytes (full + thumb) for a container.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - container_id (UUID): Container primary key.
    - session (AsyncSession): DB session dependency.

    **Exceptions:**
    - HTTPException(404): Raised when the container does not exist for this user.
    """
    user_key = request.state.user_key
    repo = ContainersRepository(session)
    now = DateTimeValue.now(tz=TZ)
    async with transaction(session):
        ok = await repo.clear_photo(container_id, user_key, now)
    if not ok:
        raise HTTPException(status_code=404, detail="Container not found")


@router.get("/containers/{container_id}/photo")
async def get_container_photo(
    request: Request,
    container_id: UUID,
    size: str = Query(default="thumb", pattern="^(thumb|full)$"),
    session: AsyncSession = Depends(get_session_dependency),
) -> Response:
    """Return raw container photo bytes (``thumb`` by default, or ``full``).

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - container_id (UUID): Container primary key.
    - size (str): ``"thumb"`` or ``"full"``; default ``"thumb"``.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - Response: Image bytes with the stored MIME type and a 24 h private cache header.

    **Exceptions:**
    - HTTPException(404): Raised when the container has no stored photo.
    """
    user_key = request.state.user_key
    repo = ContainersRepository(session)
    result = await repo.get_photo(container_id, user_key, thumb=(size == "thumb"))
    if result is None:
        raise HTTPException(status_code=404, detail="No photo")
    body, mime = result
    headers = {
        "Cache-Control": "private, max-age=86400",
    }
    return Response(content=body, media_type=mime, headers=headers)
