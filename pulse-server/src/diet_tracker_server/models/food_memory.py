from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field

from diet_tracker_server.models.custom_foods import CustomFoodBasis, CustomFoodResponse


class FoodMemoryUsdaWrite(BaseModel):
    """USDA-pointer memory entry; macros are cached at the basis indicated by `basis`."""

    name: str
    usda_fdc_id: int
    usda_description: str
    basis: CustomFoodBasis
    serving_size: float | None = None
    serving_size_unit: str | None = None
    calories: int = Field(ge=0)
    protein_g: float = Field(ge=0)
    carbs_g: float = Field(ge=0)
    fat_g: float = Field(ge=0)


class FoodMemoryCustomWrite(BaseModel):
    """Custom-food-pointer memory entry; macros come from the linked custom_food."""

    name: str
    custom_food_id: UUID


class FoodMemoryEntry(BaseModel):
    id: UUID
    user_key: str
    name: str
    normalized_name: str
    usda_fdc_id: int | None = None
    usda_description: str | None = None
    custom_food_id: UUID | None = None
    basis: CustomFoodBasis | None = None
    serving_size: float | None = None
    serving_size_unit: str | None = None
    calories: int | None = None
    protein_g: float | None = None
    carbs_g: float | None = None
    fat_g: float | None = None
    created_at: DateTimeValue
    updated_at: DateTimeValue


class FoodMemoryListResponse(BaseModel):
    entries: list[FoodMemoryEntry]


class ResolvedFood(BaseModel):
    """Unified shape returned by resolve_food. Always includes basis + macros so the model
    can scale them to the user's quantity before calling log_food."""

    type: Literal["memory_usda", "custom_food", "none"]
    name: str | None = None
    usda_fdc_id: int | None = None
    usda_description: str | None = None
    custom_food_id: UUID | None = None
    custom_food: CustomFoodResponse | None = None
    basis: CustomFoodBasis | None = None
    serving_size: float | None = None
    serving_size_unit: str | None = None
    calories: int | None = None
    protein_g: float | None = None
    carbs_g: float | None = None
    fat_g: float | None = None
