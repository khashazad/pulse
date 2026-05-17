"""DTOs for the /logs endpoints.

Defines :class:`DailyLogSummary` (per-day rollup of macros plus entry
count) and :class:`LogsListResponse` (the list wrapper). Used by the
logs router to surface a history view across multiple days.
"""

from __future__ import annotations

from datetime import date as DateValue

from pydantic import BaseModel


class DailyLogSummary(BaseModel):
    """Response fragment summarizing one day's totals and entry count."""

    date: DateValue
    total_calories: int
    total_protein_g: float
    total_carbs_g: float
    total_fat_g: float
    entry_count: int


class LogsListResponse(BaseModel):
    """Response body for ``GET /logs`` — wraps a series of daily summaries."""

    logs: list[DailyLogSummary]
