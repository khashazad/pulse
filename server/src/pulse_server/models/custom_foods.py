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

from pydantic import BaseModel, Field, model_validator

CustomFoodBasis = Literal["per_100g", "per_serving", "per_unit"]
CustomFoodSource = Literal["manual", "photo", "corrected"]

# Columns that are NOT NULL in the database. A PATCH may omit them (no-op) but
# must never set them to null, which would raise an uncaught IntegrityError.
_CUSTOM_FOOD_NON_NULLABLE = ("name", "basis", "calories", "protein_g", "carbs_g", "fat_g", "source")


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
    """Request body for ``PATCH /custom-foods/{id}`` — all fields optional for partial update.

    A field may be omitted (no-op), but explicitly setting a NOT NULL column to
    ``null`` is rejected: only the nullable columns (``serving_size``,
    ``serving_size_unit``, ``notes``) accept ``null`` to clear them.
    """

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

    @model_validator(mode="after")
    def _reject_explicit_nulls(self) -> CustomFoodUpdate:
        """Reject an explicit ``null`` for any NOT NULL column.

        Distinguishes "omitted" (absent from the request → no-op) from
        "explicitly null" (present with value ``None``) via ``model_fields_set``,
        so partial updates that simply leave a field out are unaffected.

        **Outputs:**
        - CustomFoodUpdate: This instance, unchanged, when validation passes.

        **Raises:**
        - ValueError: When a non-nullable field is explicitly set to ``null``;
          surfaced by FastAPI as a 422 response.
        """
        for field in _CUSTOM_FOOD_NON_NULLABLE:
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null")
        return self


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
