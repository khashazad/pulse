from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from uuid import UUID

from pydantic import BaseModel, Field


class MacroTotals(BaseModel):
    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float


class MacroTargets(BaseModel):
    calories: int = Field(gt=0)
    protein_g: float = Field(ge=0)
    carbs_g: float = Field(ge=0)
    fat_g: float = Field(ge=0)


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


class AliasCreate(BaseModel):
    alias_text: str
    preferred_label: str
    preferred_usda_fdc_id: int
    preferred_usda_description: str
    default_quantity_value: float | None = None
    default_quantity_unit: str | None = None
    user_key: str | None = None


class AliasResponse(BaseModel):
    id: UUID
    user_key: str
    alias_text: str
    preferred_label: str
    preferred_usda_fdc_id: int
    preferred_usda_description: str
    default_quantity_value: float | None
    default_quantity_unit: str | None
    confidence_score: float
    last_confirmed_at: DateTimeValue


class AliasListResponse(BaseModel):
    aliases: list[AliasResponse]


class MatchHistoryEntry(BaseModel):
    raw_phrase: str
    quantity_text: str | None
    usda_fdc_id: int
    usda_description: str
    times_confirmed: int
    last_confirmed_at: DateTimeValue


class MatchHistoryResponse(BaseModel):
    matches: list[MatchHistoryEntry]


class DailySummaryResponse(BaseModel):
    date: DateValue
    target: MacroTargets
    consumed: MacroTotals
    remaining: MacroTotals
    entries: list[FoodEntryResponse]


class USDAFoodResult(BaseModel):
    fdc_id: int
    description: str
    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float
    serving_size: float | None
    serving_size_unit: str | None


class USDASearchResponse(BaseModel):
    results: list[USDAFoodResult]


class DailyLogSummary(BaseModel):
    date: DateValue
    total_calories: int
    total_protein_g: float
    total_carbs_g: float
    total_fat_g: float
    entry_count: int


class LogsListResponse(BaseModel):
    logs: list[DailyLogSummary]
