"""HTTP endpoints for user-defined custom foods.

Exposes the ``/custom-foods`` router covering list, create-or-update (with
atomic food-memory write), partial update, and delete. Mutating routes defer
to :mod:`services.custom_foods_service` so the memory pointer stays in sync
inside one transaction.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.auth import require_session
from pulse_server.config import get_settings
from pulse_server.db import get_session_dependency, transaction
from pulse_server.models import (
    CustomFoodCreate,
    CustomFoodListResponse,
    CustomFoodResponse,
    CustomFoodUpdate,
    custom_food_response,
)
from pulse_server.repositories.custom_foods import CustomFoodsRepository
from pulse_server.services.custom_foods_service import upsert_custom_food_and_remember
from pulse_server.services.normalize import normalize_name

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_session)])
TZ = ZoneInfo(settings.timezone)


@router.get("/custom-foods", response_model=CustomFoodListResponse)
async def list_custom_foods(
    request: Request,
    session: AsyncSession = Depends(get_session_dependency),
) -> CustomFoodListResponse:
    """List every custom food owned by the authenticated user.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - CustomFoodListResponse: Custom foods in repository-defined order.
    """
    user_key = request.state.user_key
    repo = CustomFoodsRepository(session)
    rows = await repo.list_for_user(user_key)
    return CustomFoodListResponse(custom_foods=[custom_food_response(r) for r in rows])


@router.post("/custom-foods", status_code=201, response_model=CustomFoodResponse)
async def create_custom_food(
    request: Request,
    body: CustomFoodCreate,
    session: AsyncSession = Depends(get_session_dependency),
) -> CustomFoodResponse:
    """Create or update a custom food and write its memory pointer in one transaction.

    Delegates to :func:`upsert_custom_food_and_remember` so a single round-trip
    keeps the food and its memory entry consistent.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - body (CustomFoodCreate): Name, basis, serving info, and macros.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - CustomFoodResponse: The upserted row.
    """
    user_key = request.state.user_key
    now = DateTimeValue.now(tz=TZ)
    async with transaction(session):
        row = await upsert_custom_food_and_remember(
            session=session, user_key=user_key, payload=body, now=now
        )
    return custom_food_response(row)


@router.patch("/custom-foods/{custom_food_id}", response_model=CustomFoodResponse)
async def update_custom_food(
    request: Request,
    custom_food_id: UUID,
    body: CustomFoodUpdate,
    session: AsyncSession = Depends(get_session_dependency),
) -> CustomFoodResponse:
    """Partially update a custom food's fields. Recomputes ``normalized_name`` when
    ``name`` changes.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - custom_food_id (UUID): Custom-food primary key.
    - body (CustomFoodUpdate): Subset of fields to overwrite.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - CustomFoodResponse: The updated row.

    **Exceptions:**
    - HTTPException(409): Raised when renaming would collide with another custom food's name.
    - HTTPException(404): Raised when no custom food with that id is owned by the user.
    - HTTPException(422): Raised when a non-nullable field is explicitly set to null
      (model validation).
    """
    user_key = request.state.user_key
    fields = body.model_dump(exclude_unset=True)
    if "name" in fields and fields["name"] is not None:
        fields["normalized_name"] = normalize_name(fields["name"])
    now = DateTimeValue.now(tz=TZ)
    repo = CustomFoodsRepository(session)
    try:
        async with transaction(session):
            row = await repo.update_fields(custom_food_id, user_key, fields, now)
    except IntegrityError as exc:
        raise HTTPException(
            status_code=409,
            detail="A custom food with that name already exists",
        ) from exc
    if row is None:
        raise HTTPException(status_code=404, detail="Custom food not found")
    return custom_food_response(row)


@router.delete("/custom-foods/{custom_food_id}", status_code=204)
async def delete_custom_food(
    request: Request,
    custom_food_id: UUID,
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    """Delete a custom food. Refuses with 409 when the food is referenced elsewhere.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - custom_food_id (UUID): Custom-food primary key.
    - session (AsyncSession): DB session dependency.

    **Exceptions:**
    - HTTPException(409): Raised when foreign-key references from past entries or meal
      items prevent deletion.
    - HTTPException(404): Raised when no custom food with that id is owned by the user.
    """
    user_key = request.state.user_key
    repo = CustomFoodsRepository(session)
    try:
        async with transaction(session):
            deleted = await repo.delete(custom_food_id, user_key)
    except IntegrityError as exc:
        raise HTTPException(
            status_code=409,
            detail="Custom food is referenced by past entries or meal items",
        ) from exc
    if not deleted:
        raise HTTPException(status_code=404, detail="Custom food not found")
