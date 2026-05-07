from __future__ import annotations

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
