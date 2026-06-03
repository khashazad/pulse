"""DTOs for the /measures/weight endpoints.

Defines the weight unit literal (:data:`WeightUnit`), the request shape
for upserts (:class:`WeightEntryUpsert` — accepts ``lb`` or ``kg`` and
enforces the storable range), and the response shape
(:class:`WeightEntryResponse`). :class:`CaloriesDailyRow` now lives in
``models/daily.py`` and is re-exported here for backward-compatible imports.
Consumed by the weight router and service.
"""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from decimal import ROUND_HALF_EVEN, Decimal
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field, field_serializer, model_validator

from pulse_server.models.daily import CaloriesDailyRow

__all__ = [
    "CaloriesDailyRow",
    "WeightEntryResponse",
    "WeightEntryUpsert",
    "WeightUnit",
]

WeightUnit = Literal["lb", "kg"]

# numeric(6,2) → max 9999.99 lb. Kg input is converted with factor 2.20462262.
_MAX_WEIGHT_LB = Decimal("9999.99")
_KG_TO_LB = Decimal("2.20462262")
_MAX_WEIGHT_KG = (_MAX_WEIGHT_LB / _KG_TO_LB).quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)


class WeightEntryResponse(BaseModel):
    """Response body representing one weight entry (always stored in pounds)."""

    id: UUID
    log_date: DateValue
    weight_lb: Decimal
    source_unit: WeightUnit
    created_at: DateTimeValue
    updated_at: DateTimeValue

    # Pydantic v2 serializes Decimal as JSON string by default; emit a number so
    # clients (e.g. Swift Codable Double) can decode without custom handling.
    @field_serializer("weight_lb")
    def _serialize_weight_lb(self, v: Decimal) -> float:
        """Serialize the stored Decimal as a JSON number rather than a string.

        **Inputs:**
        - v (Decimal): The stored weight in pounds.

        **Outputs:**
        - float: ``v`` coerced to ``float`` for JSON emission.
        """
        return float(v)


class WeightEntryUpsert(BaseModel):
    """Request body for ``PUT /measures/weight/{date}`` — accepts lb or kg input."""

    weight: Decimal = Field(gt=0)
    unit: WeightUnit

    @model_validator(mode="after")
    def _check_storable(self) -> "WeightEntryUpsert":
        """Round to two decimals and reject values outside the storable range.

        **Outputs:**
        - WeightEntryUpsert: The validated model instance, unchanged.

        **Exceptions:**
        - ValueError: Raised when the rounded value is ``<= 0`` or exceeds
          the per-unit maximum (``9999.99 lb`` or the kg equivalent).
        """
        rounded = self.weight.quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)
        if rounded <= 0:
            raise ValueError("weight must be at least 0.01")
        limit = _MAX_WEIGHT_LB if self.unit == "lb" else _MAX_WEIGHT_KG
        if rounded > limit:
            raise ValueError(f"weight in {self.unit} must be <= {limit}")
        return self
