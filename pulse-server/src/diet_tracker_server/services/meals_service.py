from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.models import (
    FoodEntryCreate,
    MealCreate,
    MealItemCreate,
)
from diet_tracker_server.repositories.meals import MealsRepository
from diet_tracker_server.services.entries_service import create_entries_with_side_effects
from diet_tracker_server.services.normalize import normalize_name


# Summary: Validates that a meal item references exactly one food source (USDA or custom).
# Parameters:
# - item (MealItemCreate): Caller-supplied item payload.
# Returns:
# - None: Returns silently when the payload is valid.
# Raises/Throws:
# - fastapi.HTTPException: Raised with 422 when both or neither sources are provided.
def _validate_item_source(item: MealItemCreate) -> None:
    has_usda = item.usda_fdc_id is not None
    has_custom = item.custom_food_id is not None
    if has_usda == has_custom:
        raise HTTPException(
            status_code=422,
            detail="Each meal item must specify exactly one of usda_fdc_id or custom_food_id",
        )
    if has_usda and not item.usda_description:
        raise HTTPException(
            status_code=422,
            detail="usda_description is required when usda_fdc_id is set",
        )


# Summary: Creates a meal with its items in one transaction; macros are pre-scaled at create time.
# Parameters:
# - session (AsyncSession): Active SQLAlchemy session (caller controls transaction boundary).
# - user_key (str): Owner.
# - payload (MealCreate): Meal definition with items.
# - now (DateTimeValue): Timestamp.
# Returns:
# - tuple[dict[str, Any], list[dict[str, Any]]]: Created meal row and its inserted item rows.
# Raises/Throws:
# - fastapi.HTTPException: Raised with 422 when an item violates the exactly-one-of rule.
# - sqlalchemy.exc.IntegrityError: Raised on duplicate (user_key, normalized_name) meal name.
async def create_meal_with_items(
    session: AsyncSession,
    user_key: str,
    payload: MealCreate,
    now: DateTimeValue,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    repo = MealsRepository(session)
    for item in payload.items:
        _validate_item_source(item)

    meal_row = await repo.create_meal(
        user_key=user_key,
        name=payload.name,
        normalized_name=normalize_name(payload.name),
        notes=payload.notes,
        now=now,
    )
    item_rows: list[dict[str, Any]] = []
    for index, item in enumerate(payload.items):
        item_rows.append(
            await repo.add_meal_item(
                meal_id=meal_row["id"],
                position=index,
                display_name=item.display_name,
                quantity_text=item.quantity_text,
                normalized_quantity_value=item.normalized_quantity_value,
                normalized_quantity_unit=item.normalized_quantity_unit,
                usda_fdc_id=item.usda_fdc_id,
                usda_description=item.usda_description,
                custom_food_id=item.custom_food_id,
                calories=item.calories,
                protein_g=item.protein_g,
                carbs_g=item.carbs_g,
                fat_g=item.fat_g,
                now=now,
            )
        )
    return meal_row, item_rows


# Summary: Expands a stored meal into food entries (one shared entry_group_id).
# Parameters:
# - session (AsyncSession): Active SQLAlchemy session.
# - user_key (str): Owner.
# - meal_id (UUID): Target meal.
# - now (DateTimeValue): Default consumed_at when not specified.
# - consumed_at (DateTimeValue | None): Explicit consumption time, defaults to `now`.
# Returns:
# - tuple[list[dict[str, Any]], list[dict[str, Any]]]: Created entry rows and the full daily-log
#   rows used for totals (mirrors create_entries_with_side_effects).
# Raises/Throws:
# - fastapi.HTTPException: Raised with 404 when the meal does not exist or has no items.
async def log_meal(
    session: AsyncSession,
    user_key: str,
    meal_id: UUID,
    now: DateTimeValue,
    consumed_at: DateTimeValue | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    repo = MealsRepository(session)
    meal = await repo.get_meal(meal_id, user_key)
    if meal is None:
        raise HTTPException(status_code=404, detail="Meal not found")

    items = await repo.list_items(meal_id)
    if not items:
        raise HTTPException(status_code=400, detail="Meal has no items to log")

    effective_consumed_at = consumed_at or now
    entry_items = [
        FoodEntryCreate(
            display_name=item["display_name"],
            quantity_text=item["quantity_text"],
            normalized_quantity_value=_optional_float(item["normalized_quantity_value"]),
            normalized_quantity_unit=item["normalized_quantity_unit"],
            usda_fdc_id=item["usda_fdc_id"],
            usda_description=item["usda_description"],
            custom_food_id=item["custom_food_id"],
            calories=int(item["calories"]),
            protein_g=float(item["protein_g"]),
            carbs_g=float(item["carbs_g"]),
            fat_g=float(item["fat_g"]),
            consumed_at=effective_consumed_at,
        )
        for item in items
    ]
    return await create_entries_with_side_effects(
        session=session,
        user_key=user_key,
        items=entry_items,
        now=now,
    )


def _optional_float(value: Any) -> float | None:
    return None if value is None else float(value)
