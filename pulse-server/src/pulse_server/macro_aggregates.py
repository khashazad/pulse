"""Pure helpers for rolling food entries up into macro totals.

Provides :func:`sum_food_entry_macros`, used by services and routers to
summarize a day (or any slice) of :class:`FoodEntryResponse` records into a
single :class:`MacroTotals` payload. Stateless and side-effect free so it can
be reused anywhere a macro rollup is needed.
"""

from __future__ import annotations

from collections.abc import Sequence

from pulse_server.models import FoodEntryResponse, MacroTotals


def sum_food_entry_macros(entries: Sequence[FoodEntryResponse]) -> MacroTotals:
    """Aggregate a sequence of food entries into total macro values.

    **Inputs:**
    - entries (Sequence[FoodEntryResponse]): Food entry records to total.

    **Outputs:**
    - MacroTotals: Summed calories/protein/carbs/fat rounded to one decimal place.
    """
    return MacroTotals(
        calories=sum(entry.calories for entry in entries),
        protein_g=round(sum(entry.protein_g for entry in entries), 1),
        carbs_g=round(sum(entry.carbs_g for entry in entries), 1),
        fat_g=round(sum(entry.fat_g for entry in entries), 1),
    )
