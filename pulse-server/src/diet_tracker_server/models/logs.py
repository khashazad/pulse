from __future__ import annotations

from datetime import date as DateValue

from pydantic import BaseModel


class DailyLogSummary(BaseModel):
    date: DateValue
    total_calories: int
    total_protein_g: float
    total_carbs_g: float
    total_fat_g: float
    entry_count: int


class LogsListResponse(BaseModel):
    logs: list[DailyLogSummary]
