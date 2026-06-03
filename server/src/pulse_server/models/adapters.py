"""Canonical row→DTO adapters shared by REST routers and the MCP server.

These functions translate raw repository row mappings (column→value dicts from
the SQLAlchemy Core repositories) into the public Pydantic response DTOs. They
are the single source of truth for that projection so the REST surface and the
MCP surface build identical wire payloads from one place. The food-memory and
meal adapters include the ``aliases`` list, so every caller emits it uniformly.
"""

from __future__ import annotations

from typing import Any

from pulse_server.models.common import MacroTargets
from pulse_server.models.containers import ContainerResponse
from pulse_server.models.custom_foods import CustomFoodResponse
from pulse_server.models.food_memory import FoodMemoryEntry
from pulse_server.models.meals import MealItemResponse, MealResponse, MealSummary


def container_response(row: dict[str, Any]) -> ContainerResponse:
    """Adapt a ``containers`` repository row to its wire DTO.

    **Inputs:**
    - row (dict[str, Any]): Column→value mapping from ``ContainersRepository``.

    **Outputs:**
    - ContainerResponse: Pydantic model with floats/booleans coerced from the
      raw DB types.
    """
    return ContainerResponse(
        id=row["id"],
        user_key=row["user_key"],
        name=row["name"],
        normalized_name=row["normalized_name"],
        tare_weight_g=float(row["tare_weight_g"]),
        has_photo=bool(row["has_photo"]),
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


def custom_food_response(row: dict[str, Any]) -> CustomFoodResponse:
    """Adapt a ``custom_foods`` repository row to its wire DTO.

    **Inputs:**
    - row (dict[str, Any]): Column→value mapping from ``CustomFoodsRepository``.

    **Outputs:**
    - CustomFoodResponse: Pydantic model with numerics coerced and
      ``serving_size`` left ``None`` when the column is null.
    """
    return CustomFoodResponse(
        id=row["id"],
        user_key=row["user_key"],
        name=row["name"],
        normalized_name=row["normalized_name"],
        basis=row["basis"],
        serving_size=None if row["serving_size"] is None else float(row["serving_size"]),
        serving_size_unit=row["serving_size_unit"],
        calories=int(row["calories"]),
        protein_g=float(row["protein_g"]),
        carbs_g=float(row["carbs_g"]),
        fat_g=float(row["fat_g"]),
        source=row["source"],
        notes=row["notes"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


def food_memory_entry(row: dict[str, Any]) -> FoodMemoryEntry:
    """Adapt a ``food_memory`` repository row to its wire DTO.

    **Inputs:**
    - row (dict[str, Any]): Column→value mapping from ``FoodMemoryRepository``.

    **Outputs:**
    - FoodMemoryEntry: Pydantic model with numerics coerced, any nullable
      column passed through as ``None``, and ``aliases`` defaulted to ``[]``.
    """
    return FoodMemoryEntry(
        id=row["id"],
        user_key=row["user_key"],
        name=row["name"],
        normalized_name=row["normalized_name"],
        usda_fdc_id=None if row["usda_fdc_id"] is None else int(row["usda_fdc_id"]),
        usda_description=row["usda_description"],
        custom_food_id=row["custom_food_id"],
        basis=row["basis"],
        serving_size=None if row["serving_size"] is None else float(row["serving_size"]),
        serving_size_unit=row["serving_size_unit"],
        calories=None if row["calories"] is None else int(row["calories"]),
        protein_g=None if row["protein_g"] is None else float(row["protein_g"]),
        carbs_g=None if row["carbs_g"] is None else float(row["carbs_g"]),
        fat_g=None if row["fat_g"] is None else float(row["fat_g"]),
        aliases=list(row.get("aliases") or []),
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


def meal_item_response(row: dict[str, Any]) -> MealItemResponse:
    """Adapt a ``meal_items`` repository row to its wire DTO.

    **Inputs:**
    - row (dict[str, Any]): Column→value mapping for one meal item.

    **Outputs:**
    - MealItemResponse: Pydantic model with macros and quantity values coerced
      to the wire types.
    """
    return MealItemResponse(
        id=row["id"],
        meal_id=row["meal_id"],
        position=int(row["position"]),
        display_name=row["display_name"],
        quantity_text=row["quantity_text"],
        normalized_quantity_value=None
        if row["normalized_quantity_value"] is None
        else float(row["normalized_quantity_value"]),
        normalized_quantity_unit=row["normalized_quantity_unit"],
        usda_fdc_id=None if row["usda_fdc_id"] is None else int(row["usda_fdc_id"]),
        usda_description=row["usda_description"],
        custom_food_id=row["custom_food_id"],
        calories=int(row["calories"]),
        protein_g=float(row["protein_g"]),
        carbs_g=float(row["carbs_g"]),
        fat_g=float(row["fat_g"]),
        created_at=row["created_at"],
    )


def meal_summary(row: dict[str, Any]) -> MealSummary:
    """Adapt a ``list_meals`` repository row to its list-view DTO.

    Includes the ``aliases`` list (defaulted to ``[]``) so the REST list view
    and the MCP ``list_meals`` tool emit the same shape from one place.

    **Inputs:**
    - row (dict[str, Any]): Column→value mapping from ``MealsRepository.list_meals``
      (meal header columns plus the precomputed item count and macro totals).

    **Outputs:**
    - MealSummary: Pydantic list-view fragment with counts/macros coerced.
    """
    return MealSummary(
        id=row["id"],
        name=row["name"],
        normalized_name=row["normalized_name"],
        notes=row["notes"],
        aliases=list(row.get("aliases") or []),
        item_count=int(row["item_count"]),
        total_calories=int(row["total_calories"]),
        total_protein_g=float(row["total_protein_g"]),
        total_carbs_g=float(row["total_carbs_g"]),
        total_fat_g=float(row["total_fat_g"]),
    )


def macro_targets_from_row(row: dict[str, Any]) -> MacroTargets:
    """Adapt a ``daily_target_profile`` row to the macro-only ``MacroTargets`` DTO.

    Projects the four macro target columns; ``target_weight_lb`` is intentionally
    left at its default (``None``) — callers that surface the stored weight (the
    REST targets router) build it themselves.

    **Inputs:**
    - row (dict[str, Any]): Column→value mapping from ``TargetsRepository``.

    **Outputs:**
    - MacroTargets: Targets with the four macro fields coerced to wire types.
    """
    return MacroTargets(
        calories=int(row["calories_target"]),
        protein_g=float(row["protein_g_target"]),
        carbs_g=float(row["carbs_g_target"]),
        fat_g=float(row["fat_g_target"]),
    )


def meal_response(meal_row: dict[str, Any], item_rows: list[dict[str, Any]]) -> MealResponse:
    """Combine a meal row and its item rows into a wire DTO.

    **Inputs:**
    - meal_row (dict[str, Any]): Column→value mapping for the parent meal.
    - item_rows (list[dict[str, Any]]): Column→value mappings for each meal item,
      already ordered by position.

    **Outputs:**
    - MealResponse: Pydantic model with ``aliases`` defaulted to ``[]`` and each
      item adapted via :func:`meal_item_response`.
    """
    return MealResponse(
        id=meal_row["id"],
        user_key=meal_row["user_key"],
        name=meal_row["name"],
        normalized_name=meal_row["normalized_name"],
        notes=meal_row["notes"],
        aliases=list(meal_row.get("aliases") or []),
        created_at=meal_row["created_at"],
        updated_at=meal_row["updated_at"],
        items=[meal_item_response(r) for r in item_rows],
    )
