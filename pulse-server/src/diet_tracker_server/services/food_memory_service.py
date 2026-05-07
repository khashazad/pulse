from __future__ import annotations

from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.models import ResolvedFood
from diet_tracker_server.repositories.food_memory import FoodMemoryRepository
from diet_tracker_server.services.normalize import normalize_name


# Summary: Resolves a free-text food name against the user's memory.
# Parameters:
# - session (AsyncSession): Active SQLAlchemy session.
# - user_key (str): Owner.
# - name (str): User-supplied food phrase.
# Returns:
# - ResolvedFood: `type` is `"none"` when no memory exists, otherwise `"memory_usda"` or
#   `"custom_food"` with all fields needed to scale macros and call log_food.
# Raises/Throws:
# - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
async def resolve_food_by_name(
    session: AsyncSession,
    user_key: str,
    name: str,
) -> ResolvedFood:
    repo = FoodMemoryRepository(session)
    row = await repo.get_by_name(user_key=user_key, normalized_name=normalize_name(name))
    if row is None:
        return ResolvedFood(type="none")

    if row["custom_food_id"] is not None:
        return ResolvedFood(
            type="custom_food",
            name=row["name"],
            custom_food_id=row["custom_food_id"],
            custom_food=_custom_food_from_row(row),
            basis=row["cf_basis"],
            serving_size=_optional_float(row["cf_serving_size"]),
            serving_size_unit=row["cf_serving_size_unit"],
            calories=int(row["cf_calories"]),
            protein_g=float(row["cf_protein_g"]),
            carbs_g=float(row["cf_carbs_g"]),
            fat_g=float(row["cf_fat_g"]),
        )

    return ResolvedFood(
        type="memory_usda",
        name=row["name"],
        usda_fdc_id=int(row["usda_fdc_id"]),
        usda_description=row["usda_description"],
        basis=row["basis"],
        serving_size=_optional_float(row["serving_size"]),
        serving_size_unit=row["serving_size_unit"],
        calories=int(row["calories"]),
        protein_g=float(row["protein_g"]),
        carbs_g=float(row["carbs_g"]),
        fat_g=float(row["fat_g"]),
    )


def _optional_float(value: Any) -> float | None:
    return None if value is None else float(value)


def _custom_food_from_row(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row["cf_id"],
        "user_key": row["cf_user_key"],
        "name": row["cf_name"],
        "normalized_name": row["cf_normalized_name"],
        "basis": row["cf_basis"],
        "serving_size": _optional_float(row["cf_serving_size"]),
        "serving_size_unit": row["cf_serving_size_unit"],
        "calories": int(row["cf_calories"]),
        "protein_g": float(row["cf_protein_g"]),
        "carbs_g": float(row["cf_carbs_g"]),
        "fat_g": float(row["cf_fat_g"]),
        "source": row["cf_source"],
        "notes": row["cf_notes"],
        "created_at": row["cf_created_at"],
        "updated_at": row["cf_updated_at"],
    }
