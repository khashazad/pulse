from __future__ import annotations

from datetime import datetime as DateTimeValue
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.auth import require_api_key
from diet_tracker_server.config import get_settings
from diet_tracker_server.db import get_session_dependency, transaction
from diet_tracker_server.macro_aggregates import sum_food_entry_macros
from diet_tracker_server.models import (
    FoodEntryResponse,
    MacroTotals,
    MealCreate,
    MealItemCreate,
    MealItemResponse,
    MealResponse,
    MealSummary,
    MealUpdate,
    MealsListResponse,
)
from diet_tracker_server.repositories.meals import MealsRepository
from diet_tracker_server.services.meals_service import create_meal_with_items, log_meal
from diet_tracker_server.services.normalize import normalize_name
from pydantic import BaseModel

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_api_key)])
TZ = ZoneInfo(settings.timezone)


class LogMealRequest(BaseModel):
    consumed_at: DateTimeValue | None = None


class LogMealResponse(BaseModel):
    entries: list[FoodEntryResponse]
    daily_totals: MacroTotals


def _item_to_response(row: dict) -> MealItemResponse:
    return MealItemResponse(
        id=row["id"],
        meal_id=row["meal_id"],
        position=int(row["position"]),
        display_name=row["display_name"],
        quantity_text=row["quantity_text"],
        normalized_quantity_value=None
        if row["normalized_quantity_value"] is None
        else float(row["normalized_quantity_value"]),
        normalized_quantity_unit=row["normalized_quantity_unit"],
        usda_fdc_id=None if row["usda_fdc_id"] is None else int(row["usda_fdc_id"]),
        usda_description=row["usda_description"],
        custom_food_id=row["custom_food_id"],
        calories=int(row["calories"]),
        protein_g=float(row["protein_g"]),
        carbs_g=float(row["carbs_g"]),
        fat_g=float(row["fat_g"]),
        created_at=row["created_at"],
    )


def _meal_to_response(meal_row: dict, item_rows: list[dict]) -> MealResponse:
    return MealResponse(
        id=meal_row["id"],
        user_key=meal_row["user_key"],
        name=meal_row["name"],
        normalized_name=meal_row["normalized_name"],
        notes=meal_row["notes"],
        created_at=meal_row["created_at"],
        updated_at=meal_row["updated_at"],
        items=[_item_to_response(r) for r in item_rows],
    )


# Summary: Lists meals owned by a user with item counts.
@router.get("/meals", response_model=MealsListResponse)
async def list_meals(
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> MealsListResponse:
    effective_user_key = user_key or settings.default_user_key
    repo = MealsRepository(session)
    rows = await repo.list_meals(effective_user_key)
    return MealsListResponse(
        meals=[
            MealSummary(
                id=row["id"],
                name=row["name"],
                normalized_name=row["normalized_name"],
                notes=row["notes"],
                item_count=int(row["item_count"]),
            )
            for row in rows
        ]
    )


# Summary: Creates a meal with pre-scaled items.
@router.post("/meals", status_code=201, response_model=MealResponse)
async def create_meal(
    body: MealCreate,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> MealResponse:
    effective_user_key = user_key or settings.default_user_key
    now = DateTimeValue.now(tz=TZ)
    try:
        async with transaction(session):
            meal_row, item_rows = await create_meal_with_items(
                session=session, user_key=effective_user_key, payload=body, now=now
            )
    except IntegrityError as exc:
        raise HTTPException(status_code=409, detail="Meal name already exists") from exc
    return _meal_to_response(meal_row, item_rows)


# Summary: Fetches a meal with its items.
@router.get("/meals/{meal_id}", response_model=MealResponse)
async def get_meal(
    meal_id: UUID,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> MealResponse:
    effective_user_key = user_key or settings.default_user_key
    repo = MealsRepository(session)
    meal_row = await repo.get_meal(meal_id, effective_user_key)
    if meal_row is None:
        raise HTTPException(status_code=404, detail="Meal not found")
    item_rows = await repo.list_items(meal_id)
    return _meal_to_response(meal_row, item_rows)


# Summary: Updates meal name/notes.
@router.patch("/meals/{meal_id}", response_model=MealResponse)
async def update_meal(
    meal_id: UUID,
    body: MealUpdate,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> MealResponse:
    effective_user_key = user_key or settings.default_user_key
    fields = body.model_dump(exclude_unset=True)
    if "name" in fields and fields["name"] is not None:
        fields["normalized_name"] = normalize_name(fields["name"])
    now = DateTimeValue.now(tz=TZ)
    repo = MealsRepository(session)
    try:
        async with transaction(session):
            meal_row = await repo.update_meal(meal_id, effective_user_key, fields, now)
    except IntegrityError as exc:
        raise HTTPException(status_code=409, detail="Meal name already exists") from exc
    if meal_row is None:
        raise HTTPException(status_code=404, detail="Meal not found")
    item_rows = await repo.list_items(meal_id)
    return _meal_to_response(meal_row, item_rows)


# Summary: Deletes a meal and all its items.
@router.delete("/meals/{meal_id}", status_code=204)
async def delete_meal(
    meal_id: UUID,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    effective_user_key = user_key or settings.default_user_key
    repo = MealsRepository(session)
    async with transaction(session):
        deleted = await repo.delete_meal(meal_id, effective_user_key)
    if not deleted:
        raise HTTPException(status_code=404, detail="Meal not found")


# Summary: Adds an item to a meal.
@router.post("/meals/{meal_id}/items", status_code=201, response_model=MealItemResponse)
async def add_meal_item(
    meal_id: UUID,
    body: MealItemCreate,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> MealItemResponse:
    effective_user_key = user_key or settings.default_user_key
    has_usda = body.usda_fdc_id is not None
    has_custom = body.custom_food_id is not None
    if has_usda == has_custom:
        raise HTTPException(
            status_code=422,
            detail="Item must specify exactly one of usda_fdc_id or custom_food_id",
        )
    if has_usda and not body.usda_description:
        raise HTTPException(
            status_code=422,
            detail="usda_description is required when usda_fdc_id is set",
        )
    now = DateTimeValue.now(tz=TZ)
    repo = MealsRepository(session)
    async with transaction(session):
        meal_row = await repo.get_meal(meal_id, effective_user_key)
        if meal_row is None:
            raise HTTPException(status_code=404, detail="Meal not found")
        position = await repo.next_position(meal_id)
        row = await repo.add_meal_item(
            meal_id=meal_id,
            position=position,
            display_name=body.display_name,
            quantity_text=body.quantity_text,
            normalized_quantity_value=body.normalized_quantity_value,
            normalized_quantity_unit=body.normalized_quantity_unit,
            usda_fdc_id=body.usda_fdc_id,
            usda_description=body.usda_description,
            custom_food_id=body.custom_food_id,
            calories=body.calories,
            protein_g=body.protein_g,
            carbs_g=body.carbs_g,
            fat_g=body.fat_g,
            now=now,
        )
    return _item_to_response(row)


# Summary: Deletes a meal item.
@router.delete("/meals/{meal_id}/items/{item_id}", status_code=204)
async def delete_meal_item(
    meal_id: UUID,
    item_id: UUID,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    effective_user_key = user_key or settings.default_user_key
    repo = MealsRepository(session)
    async with transaction(session):
        meal_row = await repo.get_meal(meal_id, effective_user_key)
        if meal_row is None:
            raise HTTPException(status_code=404, detail="Meal not found")
        deleted = await repo.delete_meal_item(item_id, meal_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="Meal item not found")


# Summary: Logs every item of a meal as separate food entries (one entry_group_id).
@router.post("/meals/{meal_id}/log", response_model=LogMealResponse)
async def log_meal_endpoint(
    meal_id: UUID,
    body: LogMealRequest | None = None,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> LogMealResponse:
    effective_user_key = user_key or settings.default_user_key
    now = DateTimeValue.now(tz=TZ)
    consumed_at = body.consumed_at if body else None
    if consumed_at is not None and consumed_at.tzinfo is None:
        consumed_at = consumed_at.replace(tzinfo=TZ)
    created_rows, day_rows = await log_meal(
        session=session,
        user_key=effective_user_key,
        meal_id=meal_id,
        now=now,
        consumed_at=consumed_at,
    )
    entries = [FoodEntryResponse(**row) for row in created_rows]
    day_entries = [FoodEntryResponse(**row) for row in day_rows]
    return LogMealResponse(entries=entries, daily_totals=sum_food_entry_macros(day_entries))
