from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from uuid import UUID

from pydantic import BaseModel, Field

from nutrition_server.models.common import MacroTotals


class FoodEntryCreate(BaseModel):
    display_name: str
    quantity_text: str
    normalized_quantity_value: float | None = None
    normalized_quantity_unit: str | None = None
    usda_fdc_id: int
    usda_description: str
    calories: int = Field(ge=0)
    protein_g: float = Field(ge=0)
    carbs_g: float = Field(ge=0)
    fat_g: float = Field(ge=0)
    date: DateValue | None = None
    consumed_at: DateTimeValue | None = None


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
    usda_fdc_id: int
    usda_description: str
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
