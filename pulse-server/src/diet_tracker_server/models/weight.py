from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from decimal import Decimal
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field


WeightUnit = Literal["lb", "kg"]


class WeightEntryResponse(BaseModel):
    id: UUID
    log_date: DateValue
    weight_lb: Decimal
    source_unit: WeightUnit
    created_at: DateTimeValue
    updated_at: DateTimeValue


class WeightEntryUpsert(BaseModel):
    weight: Decimal = Field(gt=0)
    unit: WeightUnit


class CaloriesDailyRow(BaseModel):
    log_date: DateValue
    calories: int
