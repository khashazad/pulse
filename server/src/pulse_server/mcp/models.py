"""Pydantic request/response models that shape the MCP wire format.

Defines the tool-facing DTOs the FastMCP server returns: USDA search hits
(:class:`FoodCandidate`, :class:`SearchFoodResponse`), food/meal logging
results (:class:`LogFoodResponse`, :class:`LogMealResponse`), and the per-day
summary (:class:`DaySummary`). These mirror the REST surface so MCP clients and
the iOS app see the same macro shapes; the logging responses expose
``daily_totals`` to match the REST ``daily_totals`` field name.
"""

from __future__ import annotations

from datetime import date as DateValue

from pydantic import BaseModel

from pulse_server.models import (
    FoodEntryResponse,
    MacroTargets,
    MacroTotals,
    WeightEntryResponse,
)


class FoodCandidate(BaseModel):
    """One USDA search hit returned to the MCP client.

    Macros are per 100 g (``basis`` is always ``"per_100g"`` — FDC normalizes
    nutrients per 100 g for every data type; ``serving_size`` is descriptive
    metadata). The client must scale to the user's quantity before logging.
    """

    fdc_id: int
    description: str
    basis: str  # always "per_100g" for USDA search hits
    serving_size: float | None
    serving_size_unit: str | None
    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float


class SearchFoodResponse(BaseModel):
    """Envelope for ``search_food`` results: the echoed query plus candidates.

    The ``note`` field is a fixed reminder to the caller that macros are at the
    candidate's basis and must be scaled before logging.
    """

    query: str
    candidates: list[FoodCandidate]
    note: str = (
        "Macros are reported on the basis indicated by `basis`. "
        "Scale them yourself for the user's quantity, then call `log_food` with the final "
        "calories/protein_g/carbs_g/fat_g."
    )


class LogFoodResponse(BaseModel):
    """Result of logging a single food entry.

    Returns the new entry, today's running totals, and (when targets are set)
    the user's target profile plus remaining macros for the day.
    """

    entry: FoodEntryResponse
    daily_totals: MacroTotals
    target: MacroTargets | None = None
    remaining_vs_target: MacroTotals | None = None


class LogMealResponse(BaseModel):
    """Result of logging a saved meal (one food entry per item).

    Mirrors :class:`LogFoodResponse` but carries the list of entries created
    from the meal's items.
    """

    entries: list[FoodEntryResponse]
    daily_totals: MacroTotals
    target: MacroTargets | None = None
    remaining_vs_target: MacroTotals | None = None


class DaySummary(BaseModel):
    """Per-day summary returned by ``get_day``.

    Bundles the date, target profile (if any), consumed macros, remaining
    macros vs. target (if any), and all food entries for that day.
    """

    date: DateValue
    target: MacroTargets | None
    consumed: MacroTotals
    remaining: MacroTotals | None
    entries: list[FoodEntryResponse]


class MealGroup(BaseModel):
    """Macro subtotal for one meal group within a day (no individual entries).

    The ``label`` is either a saved meal's ``meal_name`` (when the entries were
    logged from a meal) or a time-of-day bucket (``breakfast``/``lunch``/
    ``dinner``/``snack``) for ad-hoc entries that have no ``meal_id``.
    """

    label: str
    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float


class RangeDay(BaseModel):
    """One calendar day's macro rollup in a ``get_range`` response.

    ``by_meal`` holds per-meal-group subtotals (ordered by the earliest entry in
    each group) and sums to ``consumed``. ``target`` is the active profile (or
    ``None`` when none is set). Unlogged days are still present (zero-filled):
    ``consumed`` is all zeros and ``by_meal`` is empty.
    """

    date: DateValue
    target: MacroTargets | None
    consumed: MacroTotals
    by_meal: list[MealGroup]


class RangeSummary(BaseModel):
    """Ranged daily macro summary returned by ``get_range``.

    Bundles the resolved (inclusive) date bounds and one :class:`RangeDay` per
    calendar day in the range. Every day in ``[from_date, to_date]`` appears,
    including unlogged days (zero-filled) — callers get a complete grid without
    gap-filling client-side.
    """

    from_date: DateValue
    to_date: DateValue
    days: list[RangeDay]


class WeightRange(BaseModel):
    """Date-range of weight entries returned by ``get_weights``.

    Bundles the resolved (inclusive) date bounds, the entries ascending by
    ``log_date``, and a light summary. All summary stats are in pounds (the
    canonical stored unit); each entry additionally carries its original
    ``source_unit``. Stat fields are ``None`` for an empty range, and
    ``net_change_lb`` is ``None`` for a range with fewer than two entries.
    """

    from_date: DateValue
    to_date: DateValue
    count: int
    entries: list[WeightEntryResponse]
    latest_lb: float | None
    min_lb: float | None
    max_lb: float | None
    net_change_lb: float | None
