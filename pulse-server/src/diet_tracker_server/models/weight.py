from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from decimal import ROUND_HALF_EVEN, Decimal
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field, model_validator


WeightUnit = Literal["lb", "kg"]

# numeric(6,2) → max 9999.99 lb. Kg input is converted with factor 2.20462262.
_MAX_WEIGHT_LB = Decimal("9999.99")
_KG_TO_LB = Decimal("2.20462262")
_MAX_WEIGHT_KG = (_MAX_WEIGHT_LB / _KG_TO_LB).quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)


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

    @model_validator(mode="after")
    def _check_storable(self) -> "WeightEntryUpsert":
        rounded = self.weight.quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)
        if rounded <= 0:
            raise ValueError("weight must be at least 0.01")
        limit = _MAX_WEIGHT_LB if self.unit == "lb" else _MAX_WEIGHT_KG
        if rounded > limit:
            raise ValueError(f"weight in {self.unit} must be <= {limit}")
        return self


class CaloriesDailyRow(BaseModel):
    log_date: DateValue
    calories: int
