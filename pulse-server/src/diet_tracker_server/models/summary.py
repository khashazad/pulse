from __future__ import annotations

from datetime import date as DateValue

from pydantic import BaseModel

from diet_tracker_server.models.common import MacroTargets, MacroTotals
from diet_tracker_server.models.entries import FoodEntryResponse


class DailySummaryResponse(BaseModel):
    date: DateValue
    target: MacroTargets
    consumed: MacroTotals
    remaining: MacroTotals
    entries: list[FoodEntryResponse]
