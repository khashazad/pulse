"""DTOs for the daily summary endpoint.

Defines :class:`DailySummaryResponse`, the composite response returned
by ``GET /summary?date=...``: target macros, consumed totals, remaining
budget, and the full entry list for the day. Composed of types defined
in ``models/common.py`` and ``models/entries.py``.
"""

from __future__ import annotations

from datetime import date as DateValue

from pydantic import BaseModel

from pulse_server.models.common import MacroTargets, MacroTotals
from pulse_server.models.entries import FoodEntryResponse


class DailySummaryResponse(BaseModel):
    """Response body for ``GET /summary?date=...`` — full daily macro picture."""

    date: DateValue
    target: MacroTargets
    consumed: MacroTotals
    remaining: MacroTotals
    entries: list[FoodEntryResponse]
