"""HTTP endpoints for progress-photo tag CRUD.

Exposes the ``/measures/photo-tags`` router covering listing (with lazy
seeding of the four legacy defaults on first call), creation, and
partial updates (rename / reorder). Tag deletion is intentionally not
implemented in this release.
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.auth import require_session
from pulse_server.db import get_session_dependency, transaction
from pulse_server.models.progress_photo import (
    ProgressPhotoTagCreate,
    ProgressPhotoTagResponse,
    ProgressPhotoTagUpdate,
)
from pulse_server.repositories.progress_photo_tag import (
    ProgressPhotoTagRepository,
)
from pulse_server.services.progress_photo_tag_service import (
    create_tag,
    list_tags,
    update_tag,
)

router = APIRouter(prefix="/measures", dependencies=[Depends(require_session)])


def _row_to_response(row: dict) -> ProgressPhotoTagResponse:
    """Project a raw ``progress_photo_tags`` row into its typed response DTO.

    **Inputs:**
    - row (dict): Column→value mapping returned by the repository.

    **Outputs:**
    - ProgressPhotoTagResponse: Typed model whose serialized JSON is
      byte-identical to the prior dict payload (``id``, ``name``,
      ``normalized_name``, ``sort_order``, ``created_at``, ``updated_at``).
    """
    return ProgressPhotoTagResponse(
        id=row["id"],
        name=row["name"],
        normalized_name=row["normalized_name"],
        sort_order=row["sort_order"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


@router.get("/photo-tags", response_model=list[ProgressPhotoTagResponse])
async def list_photo_tags(
    request: Request,
    session: AsyncSession = Depends(get_session_dependency),
) -> list[ProgressPhotoTagResponse]:
    """List the user's progress-photo tags, seeding the defaults on first call.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - list[ProgressPhotoTagResponse]: Tag rows ordered by ``(sort_order, normalized_name)``.
    """
    user_key = request.state.user_key
    repo = ProgressPhotoTagRepository(session)
    async with transaction(session):
        rows = await list_tags(repo=repo, user_key=user_key)
    return [_row_to_response(r) for r in rows]


@router.post("/photo-tags", status_code=201, response_model=ProgressPhotoTagResponse)
async def create_photo_tag(
    request: Request,
    body: ProgressPhotoTagCreate,
    session: AsyncSession = Depends(get_session_dependency),
) -> ProgressPhotoTagResponse:
    """Create a new progress-photo tag.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - body (ProgressPhotoTagCreate): Desired ``name``.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - ProgressPhotoTagResponse: The newly inserted tag row.

    **Exceptions:**
    - HTTPException(400): Raised when the name is blank after trimming.
    - HTTPException(409): Raised when the name collides with another tag.
    """
    user_key = request.state.user_key
    repo = ProgressPhotoTagRepository(session)
    async with transaction(session):
        row = await create_tag(repo=repo, user_key=user_key, name=body.name)
    return _row_to_response(row)


@router.patch("/photo-tags/{tag_id}", response_model=ProgressPhotoTagResponse)
async def update_photo_tag(
    request: Request,
    tag_id: UUID,
    body: ProgressPhotoTagUpdate,
    session: AsyncSession = Depends(get_session_dependency),
) -> ProgressPhotoTagResponse:
    """Rename or reorder an existing progress-photo tag.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - tag_id (UUID): Tag primary key.
    - body (ProgressPhotoTagUpdate): Optional new ``name`` and/or ``sort_order``.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - ProgressPhotoTagResponse: The updated tag row.

    **Exceptions:**
    - HTTPException(400): Raised when the new name is blank.
    - HTTPException(404): Raised when no tag matches.
    - HTTPException(409): Raised when the new name collides with another tag.
    """
    user_key = request.state.user_key
    repo = ProgressPhotoTagRepository(session)
    async with transaction(session):
        row = await update_tag(
            repo=repo,
            user_key=user_key,
            tag_id=tag_id,
            name=body.name,
            sort_order=body.sort_order,
        )
    return _row_to_response(row)
