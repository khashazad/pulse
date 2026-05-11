from __future__ import annotations

from datetime import datetime as DateTimeValue
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.auth import require_session
from diet_tracker_server.config import get_settings
from diet_tracker_server.db import get_session_dependency, transaction
from diet_tracker_server.models import (
    FoodMemoryCustomWrite,
    FoodMemoryEntry,
    FoodMemoryListResponse,
    FoodMemoryUsdaWrite,
    ResolvedFood,
)
from diet_tracker_server.repositories.custom_foods import CustomFoodsRepository
from diet_tracker_server.repositories.food_memory import FoodMemoryRepository
from diet_tracker_server.services.food_memory_service import resolve_food_by_name
from diet_tracker_server.services.normalize import normalize_name

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_session)])
TZ = ZoneInfo(settings.timezone)


def _to_entry(row: dict) -> FoodMemoryEntry:
    return FoodMemoryEntry(
        id=row["id"],
        user_key=row["user_key"],
        name=row["name"],
        normalized_name=row["normalized_name"],
        usda_fdc_id=None if row["usda_fdc_id"] is None else int(row["usda_fdc_id"]),
        usda_description=row["usda_description"],
        custom_food_id=row["custom_food_id"],
        basis=row["basis"],
        serving_size=None if row["serving_size"] is None else float(row["serving_size"]),
        serving_size_unit=row["serving_size_unit"],
        calories=None if row["calories"] is None else int(row["calories"]),
        protein_g=None if row["protein_g"] is None else float(row["protein_g"]),
        carbs_g=None if row["carbs_g"] is None else float(row["carbs_g"]),
        fat_g=None if row["fat_g"] is None else float(row["fat_g"]),
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


# Summary: Lists every memory entry for a user.
@router.get("/food-memory", response_model=FoodMemoryListResponse)
async def list_food_memory(
    request: Request,
    session: AsyncSession = Depends(get_session_dependency),
) -> FoodMemoryListResponse:
    user_key = request.state.user_key
    repo = FoodMemoryRepository(session)
    rows = await repo.list_for_user(user_key)
    return FoodMemoryListResponse(entries=[_to_entry(r) for r in rows])


# Summary: Resolves a free-text food name to the cached memory entry, or `type=none`.
@router.get("/food-memory/resolve", response_model=ResolvedFood)
async def resolve_food(
    request: Request,
    name: str = Query(..., min_length=1),
    session: AsyncSession = Depends(get_session_dependency),
) -> ResolvedFood:
    user_key = request.state.user_key
    return await resolve_food_by_name(session=session, user_key=user_key, name=name)


# Summary: Upserts a USDA-pointer memory entry with cached per-basis macros.
@router.put("/food-memory/usda", response_model=FoodMemoryEntry)
async def remember_food_usda(
    request: Request,
    body: FoodMemoryUsdaWrite,
    session: AsyncSession = Depends(get_session_dependency),
) -> FoodMemoryEntry:
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
    return _to_entry(row)


# Summary: Upserts a custom-food-pointer memory entry; macros come from the linked custom food.
@router.put("/food-memory/custom", response_model=FoodMemoryEntry)
async def remember_food_custom(
    request: Request,
    body: FoodMemoryCustomWrite,
    session: AsyncSession = Depends(get_session_dependency),
) -> FoodMemoryEntry:
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
    return _to_entry(row)


# Summary: Deletes a memory entry by name.
@router.delete("/food-memory", status_code=204)
async def forget_food(
    request: Request,
    name: str = Query(..., min_length=1),
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    user_key = request.state.user_key
    repo = FoodMemoryRepository(session)
    async with transaction(session):
        deleted = await repo.delete_by_name(user_key, normalize_name(name))
    if not deleted:
        raise HTTPException(status_code=404, detail="Memory entry not found")
