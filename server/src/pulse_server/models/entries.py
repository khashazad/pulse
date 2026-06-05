"""DTOs for the /entries endpoints.

Defines the request and response shapes for logging food entries against
a daily log. ``FoodEntryCreate`` is the public input contract (exactly
one of USDA or custom_food must be supplied), ``EntriesCreateRequest``
batches them, and ``FoodEntryResponse`` / ``EntriesCreateResponse`` /
``EntriesListResponse`` carry server-stamped output back to clients.
Consumed by the entries router/service and by the daily summary
response.
"""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from uuid import UUID

from pydantic import BaseModel, model_validator

from pulse_server.models.common import MacroFields, MacroTotals


class FoodEntryCreate(MacroFields):
    """Request body for one item in ``POST /entries``.

    The owning daily-log calendar date is derived server-side from
    ``consumed_at`` (projected into server timezone), or from the request's
    ``now`` when ``consumed_at`` is omitted. Clients should not — and
    cannot — pass an explicit calendar date.

    Inherits the four ``ge=0`` macro fields from :class:`MacroFields`. This is
    a request body, so the base-first field order does not affect any wire
    response.

    Note: ``meal_id`` / ``meal_name`` are intentionally NOT public input
    fields — they are server-controlled metadata stamped only by
    ``log_meal``; clients cannot supply them via ``POST /entries``. The
    corresponding fields exist on :class:`FoodEntryResponse` for read.
    """

    display_name: str
    quantity_text: str
    normalized_quantity_value: float | None = None
    normalized_quantity_unit: str | None = None
    usda_fdc_id: int | None = None
    usda_description: str | None = None
    custom_food_id: UUID | None = None
    consumed_at: DateTimeValue | None = None

    @model_validator(mode="after")
    def _exactly_one_source(self) -> FoodEntryCreate:
        """Enforce that exactly one of USDA or custom_food identifies the food source.

        **Outputs:**
        - FoodEntryCreate: The validated model instance, unchanged.

        **Exceptions:**
        - ValueError: Raised when neither or both of ``usda_fdc_id`` /
          ``custom_food_id`` are provided, or when ``usda_fdc_id`` is set
          without ``usda_description``.
        """
        has_usda = self.usda_fdc_id is not None
        has_custom = self.custom_food_id is not None
        if has_usda == has_custom:
            raise ValueError("Provide exactly one of usda_fdc_id or custom_food_id")
        if has_usda and not self.usda_description:
            raise ValueError("usda_description is required when usda_fdc_id is set")
        return self


class EntriesCreateRequest(BaseModel):
    """Request body for ``POST /entries`` — a batch of entries to insert."""

    items: list[FoodEntryCreate]


class FoodEntryResponse(BaseModel):
    """Response body representing one persisted food entry row."""

    id: UUID
    daily_log_id: UUID
    user_key: str
    entry_group_id: UUID
    display_name: str
    quantity_text: str
    normalized_quantity_value: float | None
    normalized_quantity_unit: str | None
    usda_fdc_id: int | None = None
    usda_description: str | None = None
    custom_food_id: UUID | None = None
    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float
    meal_id: UUID | None = None
    meal_name: str | None = None
    consumed_at: DateTimeValue
    created_at: DateTimeValue


class EntriesCreateResponse(BaseModel):
    """Response body for ``POST /entries`` — created rows plus recomputed daily totals."""

    entries: list[FoodEntryResponse]
    daily_totals: MacroTotals


class EntriesListResponse(BaseModel):
    """Response body for ``GET /entries?date=...`` — entries plus their daily totals."""

    date: DateValue
    entries: list[FoodEntryResponse]
    totals: MacroTotals
