from __future__ import annotations

from datetime import datetime as DateTimeValue
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, File, HTTPException, Query, Response, UploadFile
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.auth import require_api_key
from diet_tracker_server.config import get_settings
from diet_tracker_server.db import get_session_dependency, transaction
from diet_tracker_server.models import (
    ContainerCreate,
    ContainerPhotoStatus,
    ContainerResponse,
    ContainerUpdate,
    ContainersListResponse,
)
from diet_tracker_server.repositories.containers import ContainersRepository
from diet_tracker_server.services.container_photos import (
    PhotoTooLargeError,
    UnsupportedImageError,
    process_container_photo,
)
from diet_tracker_server.services.normalize import normalize_name

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_api_key)])
TZ = ZoneInfo(settings.timezone)

MAX_UPLOAD_BYTES = 10 * 1024 * 1024  # 10 MB


def _to_response(row: dict) -> ContainerResponse:
    return ContainerResponse(
        id=row["id"],
        user_key=row["user_key"],
        name=row["name"],
        normalized_name=row["normalized_name"],
        tare_weight_g=float(row["tare_weight_g"]),
        has_photo=bool(row["has_photo"]),
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


@router.get("/containers", response_model=ContainersListResponse)
async def list_containers(
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> ContainersListResponse:
    effective = user_key or settings.default_user_key
    repo = ContainersRepository(session)
    rows = await repo.list_for_user(effective)
    return ContainersListResponse(containers=[_to_response(r) for r in rows])


@router.post("/containers", status_code=201, response_model=ContainerResponse)
async def create_container(
    body: ContainerCreate,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> ContainerResponse:
    effective = user_key or settings.default_user_key
    repo = ContainersRepository(session)
    now = DateTimeValue.now(tz=TZ)
    try:
        async with transaction(session):
            row = await repo.create(
                user_key=effective,
                name=body.name,
                normalized_name=normalize_name(body.name),
                tare_weight_g=body.tare_weight_g,
                now=now,
            )
    except IntegrityError as exc:
        raise HTTPException(status_code=409, detail="A container with that name already exists") from exc
    return _to_response(row)


@router.get("/containers/{container_id}", response_model=ContainerResponse)
async def get_container(
    container_id: UUID,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> ContainerResponse:
    effective = user_key or settings.default_user_key
    repo = ContainersRepository(session)
    row = await repo.get_by_id(container_id, effective)
    if row is None:
        raise HTTPException(status_code=404, detail="Container not found")
    return _to_response(row)


@router.patch("/containers/{container_id}", response_model=ContainerResponse)
async def update_container(
    container_id: UUID,
    body: ContainerUpdate,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> ContainerResponse:
    effective = user_key or settings.default_user_key
    fields = body.model_dump(exclude_unset=True)
    if "name" in fields and fields["name"] is not None:
        fields["normalized_name"] = normalize_name(fields["name"])
    repo = ContainersRepository(session)
    now = DateTimeValue.now(tz=TZ)
    try:
        async with transaction(session):
            row = await repo.update_fields(container_id, effective, fields, now)
    except IntegrityError as exc:
        raise HTTPException(status_code=409, detail="A container with that name already exists") from exc
    if row is None:
        raise HTTPException(status_code=404, detail="Container not found")
    return _to_response(row)


@router.delete("/containers/{container_id}", status_code=204)
async def delete_container(
    container_id: UUID,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    effective = user_key or settings.default_user_key
    repo = ContainersRepository(session)
    async with transaction(session):
        deleted = await repo.delete(container_id, effective)
    if not deleted:
        raise HTTPException(status_code=404, detail="Container not found")


@router.put("/containers/{container_id}/photo", response_model=ContainerPhotoStatus)
async def upload_container_photo(
    container_id: UUID,
    file: UploadFile = File(...),
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> ContainerPhotoStatus:
    effective = user_key or settings.default_user_key
    raw = await file.read()
    try:
        full, thumb, mime = process_container_photo(raw, max_bytes=MAX_UPLOAD_BYTES)
    except PhotoTooLargeError as exc:
        raise HTTPException(status_code=413, detail=str(exc)) from exc
    except UnsupportedImageError as exc:
        raise HTTPException(status_code=415, detail="Unsupported or corrupt image") from exc

    repo = ContainersRepository(session)
    now = DateTimeValue.now(tz=TZ)
    async with transaction(session):
        ok = await repo.set_photo(
            container_id=container_id,
            user_key=effective,
            photo=full,
            photo_thumb=thumb,
            mime=mime,
            now=now,
        )
    if not ok:
        raise HTTPException(status_code=404, detail="Container not found")
    return ContainerPhotoStatus(has_photo=True)


@router.delete("/containers/{container_id}/photo", status_code=204)
async def delete_container_photo(
    container_id: UUID,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    effective = user_key or settings.default_user_key
    repo = ContainersRepository(session)
    now = DateTimeValue.now(tz=TZ)
    async with transaction(session):
        ok = await repo.clear_photo(container_id, effective, now)
    if not ok:
        raise HTTPException(status_code=404, detail="Container not found")


@router.get("/containers/{container_id}/photo")
async def get_container_photo(
    container_id: UUID,
    size: str = Query(default="thumb", pattern="^(thumb|full)$"),
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> Response:
    effective = user_key or settings.default_user_key
    repo = ContainersRepository(session)
    result = await repo.get_photo(container_id, effective, thumb=(size == "thumb"))
    if result is None:
        raise HTTPException(status_code=404, detail="No photo")
    body, mime = result
    headers = {
        "Cache-Control": "private, max-age=86400",
    }
    return Response(content=body, media_type=mime, headers=headers)
