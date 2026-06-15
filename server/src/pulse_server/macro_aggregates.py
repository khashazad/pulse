"""Pure helpers for rolling food entries up into macro totals.

Provides :func:`sum_food_entry_macros` (day/slice rollup) and
:func:`remaining_macros` (target minus consumed), used by services and the MCP
tools to build summary payloads. Stateless and side-effect free so they can be
reused anywhere a macro rollup is needed.
"""

from __future__ import annotations

from collections.abc import Sequence

from pulse_server.models import FoodEntryResponse, MacroTargets, MacroTotals


def remaining_macros(target: MacroTargets, consumed: MacroTotals) -> MacroTotals:
    """Compute remaining-vs-target macros (target minus consumed).

    **Inputs:**
    - target (MacroTargets): The user's daily macro targets.
    - consumed (MacroTotals): Macros already consumed for the day.

    **Outputs:**
    - MacroTotals: Element-wise ``target - consumed``, with macro grams rounded
      to one decimal place (calories left as an integer difference).
    """
    return MacroTotals(
        calories=target.calories - consumed.calories,
        protein_g=round(target.protein_g - consumed.protein_g, 1),
        carbs_g=round(target.carbs_g - consumed.carbs_g, 1),
        fat_g=round(target.fat_g - consumed.fat_g, 1),
    )


def confirmed_entries(entries: Sequence[FoodEntryResponse]) -> list[FoodEntryResponse]:
    """Filter a sequence of food entries down to the confirmed ones.

    Pending (unconfirmed) entries — future prep portions awaiting confirmation —
    are dropped so callers can sum only the entries that should count toward a
    day's totals.

    **Inputs:**
    - entries (Sequence[FoodEntryResponse]): Food entry records, possibly
      including unconfirmed rows.

    **Outputs:**
    - list[FoodEntryResponse]: Only the entries whose ``confirmed`` flag is
      ``True``, preserving input order.
    """
    return [entry for entry in entries if entry.confirmed]


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
