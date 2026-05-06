from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from uuid import UUID

from pydantic import BaseModel, Field, model_validator

from nutrition_server.models.common import MacroTotals


class FoodEntryCreate(BaseModel):
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
    date: DateValue | None = None
    consumed_at: DateTimeValue | None = None

    @model_validator(mode="after")
    def _exactly_one_source(self) -> "FoodEntryCreate":
        has_usda = self.usda_fdc_id is not None
        has_custom = self.custom_food_id is not None
        if has_usda == has_custom:
            raise ValueError("Provide exactly one of usda_fdc_id or custom_food_id")
        if has_usda and not self.usda_description:
            raise ValueError("usda_description is required when usda_fdc_id is set")
        return self


class EntriesCreateRequest(BaseModel):
    items: list[FoodEntryCreate]
    user_key: str | None = None


class FoodEntryResponse(BaseModel):
    id: UUID
    daily_log_id: UUID
    user_key: str
    entry_group_id: UUID
    display_name: str
    quantity_text: str
    normalized_quantity_value: float | None
    normalized_quantity_unit: str | None
    usda_fdc_id: int | None = None
    usda_description: str | None = None
    custom_food_id: UUID | None = None
    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float
    consumed_at: DateTimeValue
    created_at: DateTimeValue


class EntriesCreateResponse(BaseModel):
    entries: list[FoodEntryResponse]
    daily_totals: MacroTotals


class EntriesListResponse(BaseModel):
    date: DateValue
    entries: list[FoodEntryResponse]
    totals: MacroTotals
