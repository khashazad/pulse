"""DTOs for the per-day read endpoints (logs, summary, calorie history).

Consolidates the small day-oriented response models that previously lived in
``models/logs.py`` and ``models/summary.py`` (plus ``CaloriesDailyRow``, moved
here from ``models/weight.py``):

- :class:`DailyLogSummary` / :class:`LogsListResponse` — the ``GET /logs``
  history view (per-day macro rollups + entry counts).
- :class:`DailySummaryResponse` — the ``GET /summary?date=...`` composite of
  target / consumed / remaining macros and the day's entries.
- :class:`CaloriesDailyRow` — one day of the calorie history shown alongside
  the weight chart.

Composed of types defined in ``models/common.py`` and ``models/entries.py``.
"""

from __future__ import annotations

from datetime import date as DateValue

from pydantic import BaseModel

from pulse_server.models.common import MacroTargets, MacroTotals
from pulse_server.models.entries import FoodEntryResponse


class DailyLogSummary(BaseModel):
    """Response fragment summarizing one day's totals and entry count."""

    date: DateValue
    total_calories: int
    total_protein_g: float
    total_carbs_g: float
    total_fat_g: float
    entry_count: int
    excluded: bool = False


class LogsListResponse(BaseModel):
    """Response body for ``GET /logs`` — wraps a series of daily summaries."""

    logs: list[DailyLogSummary]


class DayExclusionRequest(BaseModel):
    """Request body for ``PUT /logs/{date}/excluded`` — the new flag value."""

    excluded: bool


class DailySummaryResponse(BaseModel):
    """Response body for ``GET /summary?date=...`` — full daily macro picture.

    The REST ``/summary`` endpoint always populates ``target``/``remaining`` (it
    404s when no profile exists). They are nullable only to support the MCP
    ``get_day`` tool's no-target mode, which returns consumed totals with
    ``target``/``remaining`` set to ``None``.
    """

    date: DateValue
    target: MacroTargets | None
    consumed: MacroTotals
    remaining: MacroTotals | None
    entries: list[FoodEntryResponse]
    excluded: bool = False


class CaloriesDailyRow(BaseModel):
    """One row of the daily calorie history used alongside the weight chart."""

    log_date: DateValue
    calories: int
    excluded: bool = False
