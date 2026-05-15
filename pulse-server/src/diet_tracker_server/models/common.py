from __future__ import annotations

from decimal import ROUND_HALF_EVEN, Decimal

from pydantic import BaseModel, Field, field_validator


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
    target_weight_lb: float | None = Field(default=None, gt=0, le=9999.99)

    @field_validator("target_weight_lb")
    @classmethod
    def _check_storable(cls, v: float | None) -> float | None:
        if v is None:
            return v
        rounded = Decimal(str(v)).quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)
        if rounded <= 0:
            raise ValueError("target_weight_lb must be at least 0.01")
        return float(rounded)
