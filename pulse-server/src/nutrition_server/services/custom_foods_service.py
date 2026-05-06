from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.models import CustomFoodCreate
from nutrition_server.repositories.custom_foods import CustomFoodsRepository
from nutrition_server.repositories.food_memory import FoodMemoryRepository
from nutrition_server.services.normalize import normalize_name


# Summary: Upserts a custom food and writes a corresponding food_memory pointer in one transaction.
# Parameters:
# - session (AsyncSession): Active SQLAlchemy session.
# - user_key (str): Owner.
# - payload (CustomFoodCreate): Custom food fields supplied by caller.
# - now (DateTimeValue): Timestamp.
# Returns:
# - dict[str, Any]: Upserted custom food row.
# Raises/Throws:
# - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails; caller controls transaction.
async def upsert_custom_food_and_remember(
    session: AsyncSession,
    user_key: str,
    payload: CustomFoodCreate,
    now: DateTimeValue,
) -> dict[str, Any]:
    foods_repo = CustomFoodsRepository(session)
    memory_repo = FoodMemoryRepository(session)
    normalized = normalize_name(payload.name)

    food_row = await foods_repo.upsert(
        user_key=user_key,
        name=payload.name,
        normalized_name=normalized,
        basis=payload.basis,
        serving_size=payload.serving_size,
        serving_size_unit=payload.serving_size_unit,
        calories=payload.calories,
        protein_g=payload.protein_g,
        carbs_g=payload.carbs_g,
        fat_g=payload.fat_g,
        source=payload.source,
        notes=payload.notes,
        now=now,
    )
    await memory_repo.upsert_custom(
        user_key=user_key,
        name=payload.name,
        normalized_name=normalized,
        custom_food_id=food_row["id"],
        now=now,
    )
    return food_row
