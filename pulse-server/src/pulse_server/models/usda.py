"""DTOs for the USDA food-search endpoint.

Defines :class:`USDAFoodResult` (a normalized USDA FoodData Central hit
already reduced to the internal macro schema) and
:class:`USDASearchResponse` (the list wrapper). Produced by the USDA
service layer after ``normalize_food_nutrients`` and returned by the
search router.
"""

from __future__ import annotations

from pydantic import BaseModel


class USDAFoodResult(BaseModel):
    """One normalized USDA search hit (macros already mapped to internal schema)."""

    fdc_id: int
    description: str
    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float
    serving_size: float | None
    serving_size_unit: str | None


class USDASearchResponse(BaseModel):
    """Response body for the USDA search endpoint — wraps the result list."""

    results: list[USDAFoodResult]
