from __future__ import annotations

from datetime import datetime as DateTimeValue
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.auth import require_api_key
from nutrition_server.config import get_settings
from nutrition_server.db import get_session_dependency, transaction
from nutrition_server.models import (
    CustomFoodCreate,
    CustomFoodListResponse,
    CustomFoodResponse,
    CustomFoodUpdate,
)
from nutrition_server.repositories.custom_foods import CustomFoodsRepository
from nutrition_server.services.custom_foods_service import upsert_custom_food_and_remember
from nutrition_server.services.normalize import normalize_name

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_api_key)])
TZ = ZoneInfo(settings.timezone)


def _to_response(row: dict) -> CustomFoodResponse:
    return CustomFoodResponse(
        id=row["id"],
        user_key=row["user_key"],
        name=row["name"],
        normalized_name=row["normalized_name"],
        basis=row["basis"],
        serving_size=None if row["serving_size"] is None else float(row["serving_size"]),
        serving_size_unit=row["serving_size_unit"],
        calories=int(row["calories"]),
        protein_g=float(row["protein_g"]),
        carbs_g=float(row["carbs_g"]),
        fat_g=float(row["fat_g"]),
        source=row["source"],
        notes=row["notes"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


# Summary: Lists all custom foods owned by the user.
@router.get("/custom-foods", response_model=CustomFoodListResponse)
async def list_custom_foods(
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> CustomFoodListResponse:
    effective_user_key = user_key or settings.default_user_key
    repo = CustomFoodsRepository(session)
    rows = await repo.list_for_user(effective_user_key)
    return CustomFoodListResponse(custom_foods=[_to_response(r) for r in rows])


# Summary: Creates or updates a custom food and writes a memory pointer atomically.
@router.post("/custom-foods", status_code=201, response_model=CustomFoodResponse)
async def create_custom_food(
    body: CustomFoodCreate,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> CustomFoodResponse:
    effective_user_key = user_key or settings.default_user_key
    now = DateTimeValue.now(tz=TZ)
    async with transaction(session):
        row = await upsert_custom_food_and_remember(
            session=session, user_key=effective_user_key, payload=body, now=now
        )
    return _to_response(row)


# Summary: Updates a subset of fields on a custom food.
@router.patch("/custom-foods/{custom_food_id}", response_model=CustomFoodResponse)
async def update_custom_food(
    custom_food_id: UUID,
    body: CustomFoodUpdate,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> CustomFoodResponse:
    effective_user_key = user_key or settings.default_user_key
    fields = body.model_dump(exclude_unset=True)
    if "name" in fields and fields["name"] is not None:
        fields["normalized_name"] = normalize_name(fields["name"])
    now = DateTimeValue.now(tz=TZ)
    repo = CustomFoodsRepository(session)
    async with transaction(session):
        row = await repo.update_fields(custom_food_id, effective_user_key, fields, now)
    if row is None:
        raise HTTPException(status_code=404, detail="Custom food not found")
    return _to_response(row)


# Summary: Deletes a custom food. Fails 409 when referenced by past entries or meal items.
@router.delete("/custom-foods/{custom_food_id}", status_code=204)
async def delete_custom_food(
    custom_food_id: UUID,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    effective_user_key = user_key or settings.default_user_key
    repo = CustomFoodsRepository(session)
    try:
        async with transaction(session):
            deleted = await repo.delete(custom_food_id, effective_user_key)
    except IntegrityError as exc:
        raise HTTPException(
            status_code=409,
            detail="Custom food is referenced by past entries or meal items",
        ) from exc
    if not deleted:
        raise HTTPException(status_code=404, detail="Custom food not found")
