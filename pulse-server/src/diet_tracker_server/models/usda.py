from __future__ import annotations

from pydantic import BaseModel


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
