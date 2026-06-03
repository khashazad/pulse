"""Public Pydantic DTO surface for the pulse-server.

Aggregates and re-exports every request/response/internal DTO used by the
HTTP routers, service layer, and tests, grouped by feature module: macro
common types, food entries, daily logs, USDA search, custom foods, food
memory, meals, containers, weight tracking, and daily summaries. This file
plays the role of the single import entry point — application code should
prefer ``from pulse_server.models import ...`` over reaching into
the individual submodules.
"""

from pulse_server.models.adapters import (
    container_response,
    custom_food_response,
    food_memory_entry,
    macro_targets_from_row,
    meal_item_response,
    meal_response,
    meal_summary,
)
from pulse_server.models.common import MacroFields, MacroTargets, MacroTotals
from pulse_server.models.containers import (
    ContainerCreate,
    ContainerPhotoStatus,
    ContainerResponse,
    ContainerUpdate,
    ContainersListResponse,
)
from pulse_server.models.custom_foods import (
    CustomFoodBasis,
    CustomFoodCreate,
    CustomFoodListResponse,
    CustomFoodResponse,
    CustomFoodSource,
    CustomFoodUpdate,
)
from pulse_server.models.entries import (
    EntriesCreateRequest,
    EntriesCreateResponse,
    EntriesListResponse,
    FoodEntryCreate,
    FoodEntryResponse,
)
from pulse_server.models.food_memory import (
    FoodMemoryCustomWrite,
    FoodMemoryEntry,
    FoodMemoryListResponse,
    FoodMemoryUsdaWrite,
    ResolvedFood,
)
from pulse_server.models.daily import (
    CaloriesDailyRow,
    DailyLogSummary,
    DailySummaryResponse,
    LogsListResponse,
)
from pulse_server.models.meals import (
    MealCreate,
    MealItemCreate,
    MealItemResponse,
    MealResponse,
    MealSummary,
    MealUpdate,
    MealsListResponse,
)
from pulse_server.models.usda import USDAFoodResult, USDASearchResponse
from pulse_server.models.weight import (
    WeightEntryResponse,
    WeightEntryUpsert,
    WeightUnit,
)

__all__ = [
    "container_response",
    "custom_food_response",
    "food_memory_entry",
    "macro_targets_from_row",
    "meal_item_response",
    "meal_response",
    "meal_summary",
    "MacroFields",
    "MacroTotals",
    "MacroTargets",
    "FoodEntryCreate",
    "EntriesCreateRequest",
    "FoodEntryResponse",
    "EntriesCreateResponse",
    "EntriesListResponse",
    "DailySummaryResponse",
    "USDAFoodResult",
    "USDASearchResponse",
    "DailyLogSummary",
    "LogsListResponse",
    "CustomFoodBasis",
    "CustomFoodSource",
    "CustomFoodCreate",
    "CustomFoodUpdate",
    "CustomFoodResponse",
    "CustomFoodListResponse",
    "FoodMemoryEntry",
    "FoodMemoryUsdaWrite",
    "FoodMemoryCustomWrite",
    "FoodMemoryListResponse",
    "ResolvedFood",
    "MealCreate",
    "MealUpdate",
    "MealItemCreate",
    "MealItemResponse",
    "MealResponse",
    "MealSummary",
    "MealsListResponse",
    "ContainerCreate",
    "ContainerUpdate",
    "ContainerResponse",
    "ContainersListResponse",
    "ContainerPhotoStatus",
    "CaloriesDailyRow",
    "WeightEntryResponse",
    "WeightEntryUpsert",
    "WeightUnit",
]
