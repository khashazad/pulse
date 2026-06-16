"""HTTP endpoints for Foods (portion parents).

Exposes ``/foods``: list (Foods with nested portions + standalones), group
(create a Food from existing custom foods), partial update, add/remove a
portion, and ungroup. Mutating routes defer to ``services.foods_service`` so the
portion links and the Food's memory entry stay consistent in one transaction.
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
    AddPortionRequest,
    FoodCreate,
    FoodListResponse,
    FoodResponse,
    FoodUpdate,
    custom_food_response,
    food_response,
)
from pulse_server.services.foods_service import (
    attach_portion,
    detach_portion,
    fetch_food_with_portions,
    group_foods,
    list_foods_with_portions,
    ungroup_food,
    update_food as update_food_service,
)

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_session)])
TZ = ZoneInfo(settings.timezone)


async def _build_food_response(
    session: AsyncSession, user_key: str, food_id: UUID
) -> FoodResponse:
    """Assemble a Food's response (row + portions + aliases) or 404.

    **Inputs:**
    - session (AsyncSession): Active session.
    - user_key (str): Owner.
    - food_id (UUID): Food id.

    **Outputs:**
    - FoodResponse: Nested DTO.

    **Raises:**
    - HTTPException(404): When the Food is not owned by the user.
    """
    result = await fetch_food_with_portions(session, user_key, food_id)
    if result is None:
        raise HTTPException(status_code=404, detail="Food not found")
    food, portions, aliases = result
    return food_response(food, portions, aliases)


@router.get("/foods", response_model=FoodListResponse)
async def list_foods(
    request: Request,
    session: AsyncSession = Depends(get_session_dependency),
) -> FoodListResponse:
    """List Foods (nested portions) plus ungrouped standalone custom foods.

    **Inputs:**
    - request (Request): Provides ``user_key``.
    - session (AsyncSession): DB session.

    **Outputs:**
    - FoodListResponse: Foods + standalones.
    """
    user_key = request.state.user_key
    foods, standalones = await list_foods_with_portions(session, user_key)
    return FoodListResponse(
        foods=[food_response(f, p, a) for (f, p, a) in foods],
        standalones=[custom_food_response(r) for r in standalones],
    )


@router.post("/foods", status_code=201, response_model=FoodResponse)
async def create_food(
    request: Request,
    body: FoodCreate,
    session: AsyncSession = Depends(get_session_dependency),
) -> FoodResponse:
    """Group existing custom foods into a new Food.

    **Inputs:**
    - request (Request): Provides ``user_key``.
    - body (FoodCreate): Name, portion ids, optional labels/default/aliases.
    - session (AsyncSession): DB session.

    **Outputs:**
    - FoodResponse: The created Food with its portions.

    **Raises:**
    - HTTPException(400/409/422): Propagated from ``group_foods``.
    """
    user_key = request.state.user_key
    now = DateTimeValue.now(tz=TZ)
    async with transaction(session):
        food_row, portion_rows, aliases = await group_foods(
            session=session, user_key=user_key, payload=body, now=now
        )
    return food_response(food_row, portion_rows, aliases)


@router.patch("/foods/{food_id}", response_model=FoodResponse)
async def update_food(
    request: Request,
    food_id: UUID,
    body: FoodUpdate,
    session: AsyncSession = Depends(get_session_dependency),
) -> FoodResponse:
    """Update a Food's name, default portion, or aliases.

    **Inputs:**
    - request (Request): Provides ``user_key``.
    - food_id (UUID): Food id.
    - body (FoodUpdate): Subset of fields to overwrite.
    - session (AsyncSession): DB session.

    **Outputs:**
    - FoodResponse: The updated Food.

    **Raises:**
    - HTTPException(404): Food not found.
    - HTTPException(409): Rename collides with another Food.
    """
    user_key = request.state.user_key
    now = DateTimeValue.now(tz=TZ)
    fields = body.model_dump(exclude_unset=True)
    aliases = fields.pop("aliases", None)
    try:
        async with transaction(session):
            await update_food_service(session, user_key, food_id, fields, aliases, now)
    except IntegrityError as exc:
        raise HTTPException(status_code=409, detail="A food with that name already exists") from exc
    return await _build_food_response(session, user_key, food_id)


@router.post("/foods/{food_id}/portions", status_code=201, response_model=FoodResponse)
async def add_portion(
    request: Request,
    food_id: UUID,
    body: AddPortionRequest,
    session: AsyncSession = Depends(get_session_dependency),
) -> FoodResponse:
    """Attach an existing custom food to a Food as a portion.

    **Inputs:**
    - request (Request): Provides ``user_key``.
    - food_id (UUID): Food id.
    - body (AddPortionRequest): Portion custom-food id + optional label.
    - session (AsyncSession): DB session.

    **Outputs:**
    - FoodResponse: The Food including the new portion.

    **Raises:**
    - HTTPException(404): Food or custom food not found.
    """
    user_key = request.state.user_key
    now = DateTimeValue.now(tz=TZ)
    async with transaction(session):
        await attach_portion(session, user_key, food_id, body.custom_food_id, body.portion_label, now)
    return await _build_food_response(session, user_key, food_id)


@router.delete("/foods/{food_id}/portions/{custom_food_id}", response_model=FoodResponse)
async def remove_portion(
    request: Request,
    food_id: UUID,
    custom_food_id: UUID,
    session: AsyncSession = Depends(get_session_dependency),
) -> FoodResponse:
    """Detach a portion from a Food (the custom food survives as a standalone).

    **Inputs:**
    - request (Request): Provides ``user_key``.
    - food_id (UUID): Food id.
    - custom_food_id (UUID): Portion to detach.
    - session (AsyncSession): DB session.

    **Outputs:**
    - FoodResponse: The Food without the detached portion.

    **Raises:**
    - HTTPException(404): Food not found.
    """
    user_key = request.state.user_key
    now = DateTimeValue.now(tz=TZ)
    async with transaction(session):
        await detach_portion(session, user_key, food_id, custom_food_id, now)
    return await _build_food_response(session, user_key, food_id)


@router.delete("/foods/{food_id}", status_code=204)
async def delete_food(
    request: Request,
    food_id: UUID,
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    """Ungroup a Food: detach its portions and delete it.

    **Inputs:**
    - request (Request): Provides ``user_key``.
    - food_id (UUID): Food id.
    - session (AsyncSession): DB session.

    **Raises:**
    - HTTPException(404): Food not found.
    """
    user_key = request.state.user_key
    now = DateTimeValue.now(tz=TZ)
    async with transaction(session):
        ok = await ungroup_food(session, user_key, food_id, now)
    if not ok:
        raise HTTPException(status_code=404, detail="Food not found")
