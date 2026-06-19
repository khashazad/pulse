"""DTOs for the /meals endpoints.

Defines the create/update/response shapes for user-authored "meals"
(named bundles of food items that can be logged in one shot). Covers
both per-item structures (:class:`MealItemCreate`,
:class:`MealItemResponse`) and meal-level structures (:class:`MealCreate`,
:class:`MealUpdate`, :class:`MealResponse`, :class:`MealSummary`,
:class:`MealsListResponse`). Consumed by the meals router/service and
by the MCP nutrition layer's ``log_meal`` flow.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from uuid import UUID

from pydantic import BaseModel, Field

from pulse_server.models.common import MacroFields


class MealItemCreate(MacroFields):
    """Request fragment describing one ingredient in a meal being created.

    Inherits the four ``ge=0`` macro fields from :class:`MacroFields`. This is
    a request fragment, so the base-first field order does not affect any wire
    response.
    """

    display_name: str
    quantity_text: str
    normalized_quantity_value: float | None = None
    normalized_quantity_unit: str | None = None
    usda_fdc_id: int | None = None
    usda_description: str | None = None
    custom_food_id: UUID | None = None


class MealItemResponse(BaseModel):
    """Response fragment representing one persisted meal-item row."""

    id: UUID
    meal_id: UUID
    position: int
    display_name: str
    quantity_text: str
    normalized_quantity_value: float | None
    normalized_quantity_unit: str | None
    usda_fdc_id: int | None
    usda_description: str | None
    custom_food_id: UUID | None
    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float
    created_at: DateTimeValue


class MealItemUpdate(BaseModel):
    """Request body for ``PATCH /meals/{id}/items/{item_id}`` — partial item update.

    All fields optional; only the mutable fields are accepted. The food source
    (``usda_fdc_id`` / ``custom_food_id``) cannot be changed in place — delete
    and re-add to switch sources.
    """

    display_name: str | None = None
    quantity_text: str | None = None
    normalized_quantity_value: float | None = None
    normalized_quantity_unit: str | None = None
    calories: int | None = Field(default=None, ge=0)
    protein_g: float | None = Field(default=None, ge=0)
    carbs_g: float | None = Field(default=None, ge=0)
    fat_g: float | None = Field(default=None, ge=0)


class MealCreate(BaseModel):
    """Request body for ``POST /meals`` — meal header plus initial items and aliases."""

    name: str
    notes: str | None = None
    items: list[MealItemCreate] = Field(default_factory=list)
    aliases: list[str] = Field(default_factory=list)


class MealUpdate(BaseModel):
    """Request body for ``PATCH /meals/{id}`` — partial header update (items handled separately)."""

    name: str | None = None
    notes: str | None = None


class MealResponse(BaseModel):
    """Response body representing a meal plus its full item list."""

    id: UUID
    user_key: str
    name: str
    normalized_name: str
    notes: str | None
    aliases: list[str] = Field(default_factory=list)
    created_at: DateTimeValue
    updated_at: DateTimeValue
    items: list[MealItemResponse] = Field(default_factory=list)


class MealSummary(BaseModel):
    """Response fragment for list views — header info plus precomputed totals."""

    id: UUID
    name: str
    normalized_name: str
    notes: str | None
    aliases: list[str] = Field(default_factory=list)
    item_count: int
    total_calories: int = 0
    total_protein_g: float = 0.0
    total_carbs_g: float = 0.0
    total_fat_g: float = 0.0


class MealsListResponse(BaseModel):
    """Response body for ``GET /meals`` — wraps the meal summaries."""

    meals: list[MealSummary]
