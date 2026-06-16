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
from pulse_server.repositories.custom_foods import CustomFoodsRepository
from pulse_server.repositories.food_memory import FoodMemoryRepository
from pulse_server.repositories.foods import FoodsRepository
from pulse_server.services.foods_service import (
    derive_portion_label,
    group_foods,
    list_foods_with_portions,
    ungroup_food,
)
from pulse_server.services.normalize import normalize_name

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
    foods_repo = FoodsRepository(session)
    cf_repo = CustomFoodsRepository(session)
    mem_repo = FoodMemoryRepository(session)
    food = await foods_repo.get_by_id(food_id, user_key)
    if food is None:
        raise HTTPException(status_code=404, detail="Food not found")
    portions = await cf_repo.list_by_food(food_id)
    mem = await mem_repo.get_by_food_id(user_key, food_id)
    aliases = list((mem.get("aliases") if mem else None) or [])
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
    foods_repo = FoodsRepository(session)
    mem_repo = FoodMemoryRepository(session)
    if "name" in fields and fields["name"] is not None:
        fields["normalized_name"] = normalize_name(fields["name"])
    try:
        async with transaction(session):
            food = await foods_repo.get_by_id(food_id, user_key)
            if food is None:
                raise HTTPException(status_code=404, detail="Food not found")
            old_norm = food["normalized_name"]
            existing_mem = await mem_repo.get_by_food_id(user_key, food_id)
            existing_aliases = list((existing_mem.get("aliases") if existing_mem else None) or [])
            if fields:
                await foods_repo.update_fields(food_id, user_key, fields, now)
            new_name = fields.get("name", food["name"])
            new_norm = fields.get("normalized_name", old_norm)
            renaming = new_norm != old_norm
            if renaming:
                await mem_repo.delete_by_name(user_key, old_norm)
            if aliases is not None:
                new_aliases: list[str] | None = [normalize_name(a) for a in aliases]
            elif renaming:
                new_aliases = existing_aliases
            else:
                new_aliases = None
            if new_aliases is not None:
                new_aliases = [a for a in new_aliases if a != new_norm]
            if new_aliases is not None or renaming:
                await mem_repo.upsert_food(
                    user_key=user_key,
                    name=new_name,
                    normalized_name=new_norm,
                    food_id=food_id,
                    now=now,
                    aliases=new_aliases,
                )
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
    foods_repo = FoodsRepository(session)
    cf_repo = CustomFoodsRepository(session)
    mem_repo = FoodMemoryRepository(session)
    async with transaction(session):
        food = await foods_repo.get_by_id(food_id, user_key)
        if food is None:
            raise HTTPException(status_code=404, detail="Food not found")
        cf = await cf_repo.get_by_id(body.custom_food_id, user_key)
        if cf is None:
            raise HTTPException(status_code=404, detail="Custom food not found")
        label = body.portion_label or derive_portion_label(food["name"], cf["name"])
        await cf_repo.set_food_link(body.custom_food_id, user_key, food_id, label, now)
        await mem_repo.delete_by_name(user_key, cf["normalized_name"])
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
    foods_repo = FoodsRepository(session)
    cf_repo = CustomFoodsRepository(session)
    mem_repo = FoodMemoryRepository(session)
    async with transaction(session):
        food = await foods_repo.get_by_id(food_id, user_key)
        if food is None:
            raise HTTPException(status_code=404, detail="Food not found")
        cf = await cf_repo.get_by_id(custom_food_id, user_key)
        await cf_repo.set_food_link(custom_food_id, user_key, None, None, now)
        if cf is not None:
            # Remove the portion's name from the Food's memory aliases before
            # restoring a standalone row; the alias-uniqueness trigger rejects
            # a row whose normalized_name appears as an alias elsewhere.
            await mem_repo.remove_alias(user_key, food["normalized_name"], cf["normalized_name"], now)
            await mem_repo.upsert_custom(
                user_key=user_key,
                name=cf["name"],
                normalized_name=cf["normalized_name"],
                custom_food_id=custom_food_id,
                now=now,
            )
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
