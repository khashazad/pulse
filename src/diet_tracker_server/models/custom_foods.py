"""DTOs for the /custom-foods endpoints.

Defines the create/update/response shapes for user-authored "custom
foods" — foods not backed by USDA, typically derived from a photo or a
user-supplied label. Also exports the ``CustomFoodBasis`` and
``CustomFoodSource`` literal aliases reused by the food-memory module.
Consumed by the custom foods router/service and by ``ResolvedFood`` in
food memory.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field

CustomFoodBasis = Literal["per_100g", "per_serving", "per_unit"]
CustomFoodSource = Literal["manual", "photo", "corrected"]


class CustomFoodCreate(BaseModel):
    """Request body for ``POST /custom-foods`` — full creation payload."""

    name: str
    basis: CustomFoodBasis
    serving_size: float | None = None
    serving_size_unit: str | None = None
    calories: int = Field(ge=0)
    protein_g: float = Field(ge=0)
    carbs_g: float = Field(ge=0)
    fat_g: float = Field(ge=0)
    source: CustomFoodSource = "manual"
    notes: str | None = None


class CustomFoodUpdate(BaseModel):
    """Request body for ``PATCH /custom-foods/{id}`` — all fields optional for partial update."""

    name: str | None = None
    basis: CustomFoodBasis | None = None
    serving_size: float | None = None
    serving_size_unit: str | None = None
    calories: int | None = Field(default=None, ge=0)
    protein_g: float | None = Field(default=None, ge=0)
    carbs_g: float | None = Field(default=None, ge=0)
    fat_g: float | None = Field(default=None, ge=0)
    source: CustomFoodSource | None = None
    notes: str | None = None


class CustomFoodResponse(BaseModel):
    """Response body representing a single custom-food row."""

    id: UUID
    user_key: str
    name: str
    normalized_name: str
    basis: CustomFoodBasis
    serving_size: float | None
    serving_size_unit: str | None
    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float
    source: CustomFoodSource
    notes: str | None
    created_at: DateTimeValue
    updated_at: DateTimeValue


class CustomFoodListResponse(BaseModel):
    """Response body for ``GET /custom-foods`` — wraps the custom-food list."""

    custom_foods: list[CustomFoodResponse]
