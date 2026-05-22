"""DTOs for the food-memory feature.

Food memory lets the server remember "the next time this user says
'oatmeal', resolve directly to this USDA food or custom food" without
re-running a search. This module defines the write shapes
(:class:`FoodMemoryUsdaWrite`, :class:`FoodMemoryCustomWrite`), the read
shape (:class:`FoodMemoryEntry`), and the unified
:class:`ResolvedFood` returned by ``resolve_food`` to drive scaling
before logging. Consumed by the food-memory router, the resolve service,
and the MCP nutrition layer.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field

from pulse_server.models.custom_foods import CustomFoodBasis, CustomFoodResponse


class FoodMemoryUsdaWrite(BaseModel):
    """USDA-pointer memory entry; macros are cached at the basis indicated by ``basis``.

    Request body for remembering a USDA food under a user-chosen name so
    future mentions resolve without hitting USDA search.
    """

    name: str
    usda_fdc_id: int
    usda_description: str
    basis: CustomFoodBasis
    serving_size: float | None = None
    serving_size_unit: str | None = None
    calories: int = Field(ge=0)
    protein_g: float = Field(ge=0)
    carbs_g: float = Field(ge=0)
    fat_g: float = Field(ge=0)


class FoodMemoryCustomWrite(BaseModel):
    """Custom-food-pointer memory entry; macros come from the linked custom_food.

    Request body for remembering a custom food under a user-chosen name.
    """

    name: str
    custom_food_id: UUID


class FoodMemoryEntry(BaseModel):
    """Response body representing one food-memory row (USDA- or custom-backed)."""

    id: UUID
    user_key: str
    name: str
    normalized_name: str
    usda_fdc_id: int | None = None
    usda_description: str | None = None
    custom_food_id: UUID | None = None
    basis: CustomFoodBasis | None = None
    serving_size: float | None = None
    serving_size_unit: str | None = None
    calories: int | None = None
    protein_g: float | None = None
    carbs_g: float | None = None
    fat_g: float | None = None
    aliases: list[str] = Field(default_factory=list)
    created_at: DateTimeValue
    updated_at: DateTimeValue


class FoodMemoryListResponse(BaseModel):
    """Response body for the list-memory endpoint — wraps the memory entries."""

    entries: list[FoodMemoryEntry]


class ResolvedFood(BaseModel):
    """Unified shape returned by ``resolve_food``.

    Always includes basis + macros so the model can scale them to the
    user's quantity before calling ``log_food``. ``type`` discriminates
    between a USDA memory hit, a custom-food hit, and a miss.
    """

    type: Literal["memory_usda", "custom_food", "none"]
    name: str | None = None
    usda_fdc_id: int | None = None
    usda_description: str | None = None
    custom_food_id: UUID | None = None
    custom_food: CustomFoodResponse | None = None
    basis: CustomFoodBasis | None = None
    serving_size: float | None = None
    serving_size_unit: str | None = None
    calories: int | None = None
    protein_g: float | None = None
    carbs_g: float | None = None
    fat_g: float | None = None
