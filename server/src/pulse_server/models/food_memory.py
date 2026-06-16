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

from pulse_server.models.common import MacroFields
from pulse_server.models.custom_foods import CustomFoodBasis, CustomFoodResponse
from pulse_server.models.foods import FoodPortion


class FoodMemoryUsdaWrite(MacroFields):
    """USDA-pointer memory entry; macros are cached at the basis indicated by ``basis``.

    Request body for remembering a USDA food under a user-chosen name so
    future mentions resolve without hitting USDA search. Inherits the four
    ``ge=0`` macro fields from :class:`MacroFields`; as a request body, the
    base-first field order does not affect any wire response.
    """

    name: str
    usda_fdc_id: int
    usda_description: str
    basis: CustomFoodBasis
    serving_size: float | None = None
    serving_size_unit: str | None = None


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
    between a USDA memory hit, a custom-food hit, a grouped Food hit,
    and a miss.

    ``type="memory_usda"`` — USDA memory hit; use ``usda_fdc_id`` + cached macros.
    ``type="custom_food"`` — custom-food hit; use ``custom_food_id`` + cached macros.
    ``type="food"`` — grouped Food hit; ``portions`` lists every :class:`FoodPortion`
    (each with its own ``custom_food_id`` + per-portion macros). The caller picks a
    portion, scales its macros to the user's quantity, and logs using that portion's
    ``custom_food_id``. ``default_portion_id`` identifies the suggested starting
    portion (may be ``None`` if none was designated).
    ``type="none"`` — no match; fall back to USDA search.
    """

    type: Literal["memory_usda", "custom_food", "food", "none"]
    name: str | None = None
    usda_fdc_id: int | None = None
    usda_description: str | None = None
    custom_food_id: UUID | None = None
    custom_food: CustomFoodResponse | None = None
    food_id: UUID | None = None
    default_portion_id: UUID | None = None
    portions: list[FoodPortion] = Field(default_factory=list)
    basis: CustomFoodBasis | None = None
    serving_size: float | None = None
    serving_size_unit: str | None = None
    calories: int | None = None
    protein_g: float | None = None
    carbs_g: float | None = None
    fat_g: float | None = None
