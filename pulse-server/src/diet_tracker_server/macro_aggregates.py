from __future__ import annotations

from collections.abc import Sequence

from diet_tracker_server.models import FoodEntryResponse, MacroTotals


# Summary: Aggregates a sequence of food entries into total macro values.
# Parameters:
# - entries: Food entry records to total.
# Returns:
# - MacroTotals: Summed calories/protein/carbs/fat rounded to one decimal place.
# Raises/Throws:
# - None: Numeric aggregation is deterministic for valid entry payloads.
def sum_food_entry_macros(entries: Sequence[FoodEntryResponse]) -> MacroTotals:
    return MacroTotals(
        calories=sum(entry.calories for entry in entries),
        protein_g=round(sum(entry.protein_g for entry in entries), 1),
        carbs_g=round(sum(entry.carbs_g for entry in entries), 1),
        fat_g=round(sum(entry.fat_g for entry in entries), 1),
    )
