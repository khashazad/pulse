"""HTTP endpoints for the per-user food-memory cache.

Exposes the ``/food-memory`` router covering list, name-resolve (returns the
cached pointer or ``type=none``), upsert of USDA-backed memories, upsert of
custom-food-backed memories, and delete by name. Used by the iOS client to
short-circuit USDA round-trips for foods the user has already logged.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.auth import require_session
from pulse_server.config import get_settings
from pulse_server.db import get_session_dependency, transaction
from pulse_server.models import (
    FoodMemoryCustomWrite,
    FoodMemoryEntry,
    FoodMemoryListResponse,
    FoodMemoryUsdaWrite,
    ResolvedFood,
    food_memory_entry,
)
from pulse_server.repositories.custom_foods import CustomFoodsRepository
from pulse_server.repositories.food_memory import FoodMemoryRepository
from pulse_server.services.food_memory_service import resolve_food_by_name
from pulse_server.services.normalize import normalize_name

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_session)])
TZ = ZoneInfo(settings.timezone)


@router.get("/food-memory", response_model=FoodMemoryListResponse)
async def list_food_memory(
    request: Request,
    session: AsyncSession = Depends(get_session_dependency),
) -> FoodMemoryListResponse:
    """List every food-memory entry owned by the authenticated user.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - FoodMemoryListResponse: Memory entries in repository-defined order.
    """
    user_key = request.state.user_key
    repo = FoodMemoryRepository(session)
    rows = await repo.list_for_user(user_key)
    return FoodMemoryListResponse(entries=[food_memory_entry(r) for r in rows])


@router.get("/food-memory/resolve", response_model=ResolvedFood)
async def resolve_food(
    request: Request,
    name: str = Query(..., min_length=1),
    session: AsyncSession = Depends(get_session_dependency),
) -> ResolvedFood:
    """Resolve a free-text food name to a cached memory entry or ``type=none``.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - name (str): Free-text food name to resolve; must be non-empty.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - ResolvedFood: Discriminated-union payload identifying the memory match
      (USDA pointer, custom-food pointer, or ``none``).
    """
    user_key = request.state.user_key
    return await resolve_food_by_name(session=session, user_key=user_key, name=name)


@router.put("/food-memory/usda", response_model=FoodMemoryEntry)
async def remember_food_usda(
    request: Request,
    body: FoodMemoryUsdaWrite,
    session: AsyncSession = Depends(get_session_dependency),
) -> FoodMemoryEntry:
    """Upsert a USDA-pointer memory entry with cached per-basis macros.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - body (FoodMemoryUsdaWrite): Name, USDA id, basis, serving info, and per-basis macros.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - FoodMemoryEntry: The upserted memory row.
    """
    user_key = request.state.user_key
    now = DateTimeValue.now(tz=TZ)
    repo = FoodMemoryRepository(session)
    async with transaction(session):
        row = await repo.upsert_usda(
            user_key=user_key,
            name=body.name,
            normalized_name=normalize_name(body.name),
            usda_fdc_id=body.usda_fdc_id,
            usda_description=body.usda_description,
            basis=body.basis,
            serving_size=body.serving_size,
            serving_size_unit=body.serving_size_unit,
            calories=body.calories,
            protein_g=body.protein_g,
            carbs_g=body.carbs_g,
            fat_g=body.fat_g,
            now=now,
        )
    return food_memory_entry(row)


@router.put("/food-memory/custom", response_model=FoodMemoryEntry)
async def remember_food_custom(
    request: Request,
    body: FoodMemoryCustomWrite,
    session: AsyncSession = Depends(get_session_dependency),
) -> FoodMemoryEntry:
    """Upsert a custom-food-pointer memory entry; macros are sourced from the linked custom food.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - body (FoodMemoryCustomWrite): Name and ``custom_food_id`` to link.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - FoodMemoryEntry: The upserted memory row.

    **Exceptions:**
    - HTTPException(404): Raised when the referenced custom food does not exist for the user.
    """
    user_key = request.state.user_key
    now = DateTimeValue.now(tz=TZ)
    custom_foods_repo = CustomFoodsRepository(session)
    if await custom_foods_repo.get_by_id(body.custom_food_id, user_key) is None:
        raise HTTPException(status_code=404, detail="Custom food not found")
    repo = FoodMemoryRepository(session)
    async with transaction(session):
        row = await repo.upsert_custom(
            user_key=user_key,
            name=body.name,
            normalized_name=normalize_name(body.name),
            custom_food_id=body.custom_food_id,
            now=now,
        )
    return food_memory_entry(row)


@router.delete("/food-memory", status_code=204)
async def forget_food(
    request: Request,
    name: str = Query(..., min_length=1),
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    """Delete the memory entry whose normalized name matches ``name``.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - name (str): Free-text food name; normalized server-side before lookup.
    - session (AsyncSession): DB session dependency.

    **Exceptions:**
    - HTTPException(404): Raised when no memory entry matches the normalized name.
    """
    user_key = request.state.user_key
    repo = FoodMemoryRepository(session)
    async with transaction(session):
        deleted = await repo.delete_by_name(user_key, normalize_name(name))
    if not deleted:
        raise HTTPException(status_code=404, detail="Memory entry not found")
