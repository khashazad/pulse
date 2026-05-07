from __future__ import annotations

from datetime import datetime as DateTimeValue
from uuid import UUID

from pydantic import BaseModel, Field


class MealItemCreate(BaseModel):
    display_name: str
    quantity_text: str
    normalized_quantity_value: float | None = None
    normalized_quantity_unit: str | None = None
    usda_fdc_id: int | None = None
    usda_description: str | None = None
    custom_food_id: UUID | None = None
    calories: int = Field(ge=0)
    protein_g: float = Field(ge=0)
    carbs_g: float = Field(ge=0)
    fat_g: float = Field(ge=0)


class MealItemResponse(BaseModel):
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


class MealCreate(BaseModel):
    name: str
    notes: str | None = None
    items: list[MealItemCreate] = Field(default_factory=list)


class MealUpdate(BaseModel):
    name: str | None = None
    notes: str | None = None


class MealResponse(BaseModel):
    id: UUID
    user_key: str
    name: str
    normalized_name: str
    notes: str | None
    created_at: DateTimeValue
    updated_at: DateTimeValue
    items: list[MealItemResponse] = Field(default_factory=list)


class MealSummary(BaseModel):
    id: UUID
    name: str
    normalized_name: str
    notes: str | None
    item_count: int


class MealsListResponse(BaseModel):
    meals: list[MealSummary]
