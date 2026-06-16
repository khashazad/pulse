"""DTOs for the /foods endpoints.

A Food is a thin parent grouping portion-variants of one custom food. The
group action (:class:`FoodCreate`) links existing custom foods (portions) under
a new Food; responses nest the portions. Aliases are not modelled here — they
live in the Food's ``food_memory`` row.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from uuid import UUID

from pydantic import BaseModel, Field

from pulse_server.models.custom_foods import CustomFoodBasis, CustomFoodResponse


class FoodCreate(BaseModel):
    """Request body for ``POST /foods`` — group existing custom foods into a Food."""

    name: str
    portion_ids: list[UUID] = Field(min_length=1)
    default_portion_id: UUID | None = None
    portion_labels: dict[UUID, str] = Field(default_factory=dict)
    aliases: list[str] = Field(default_factory=list)


class FoodUpdate(BaseModel):
    """Request body for ``PATCH /foods/{id}`` — partial update."""

    name: str | None = None
    default_portion_id: UUID | None = None
    aliases: list[str] | None = None


class AddPortionRequest(BaseModel):
    """Request body for ``POST /foods/{id}/portions`` — attach one portion."""

    custom_food_id: UUID
    portion_label: str | None = None


class FoodPortion(BaseModel):
    """A single portion within a Food response."""

    custom_food_id: UUID
    label: str | None
    basis: CustomFoodBasis
    serving_size: float | None
    serving_size_unit: str | None
    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float


class FoodResponse(BaseModel):
    """Response body for one Food with its nested portions."""

    id: UUID
    user_key: str
    name: str
    normalized_name: str
    notes: str | None
    default_portion_id: UUID | None
    aliases: list[str] = Field(default_factory=list)
    portions: list[FoodPortion] = Field(default_factory=list)
    created_at: DateTimeValue
    updated_at: DateTimeValue


class FoodListResponse(BaseModel):
    """Response body for ``GET /foods`` — Foods plus ungrouped standalones."""

    foods: list[FoodResponse] = Field(default_factory=list)
    standalones: list[CustomFoodResponse] = Field(default_factory=list)
