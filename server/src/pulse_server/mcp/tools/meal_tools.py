"""MCP tools for reusable meals and the meal-log shortcut.

Registers meal CRUD (``create_meal``, ``list_meals``, ``get_meal``,
``update_meal``, ``delete_meal``), per-item CRUD (``add_meal_item``,
``update_meal_item``, ``delete_meal_item``), alias management (``add_meal_alias``,
``remove_meal_alias``), and ``log_meal`` (expand a saved meal into food entries
sharing one ``entry_group_id``). Meal responses are built via the shared
:func:`meal_response`/:func:`meal_item_response` adapters so MCP and REST emit
one shape (including the ``aliases`` list).
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from fastapi import HTTPException
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from sqlalchemy.exc import IntegrityError

from pulse_server.db import get_session, transaction
from pulse_server.macro_aggregates import sum_food_entry_macros
from pulse_server.mcp.context import ToolContext, parse_consumed_at, target_and_remaining
from pulse_server.mcp.models import LogMealResponse
from pulse_server.models import (
    FoodEntryResponse,
    MealCreate,
    MealItemCreate,
    MealItemResponse,
    MealResponse,
    MealSummary,
    MealUpdate,
    meal_item_response,
    meal_response,
    meal_summary,
)
from pulse_server.repositories.meals import MealsRepository
from pulse_server.repositories.targets import TargetsRepository
from pulse_server.services.custom_foods_service import (
    CrossTenantReferenceError,
    assert_custom_foods_owned,
)
from pulse_server.services.meals_service import (
    assert_meal_alias_available,
    create_meal_with_items,
)
from pulse_server.services.meals_service import log_meal as log_meal_service
from pulse_server.services.normalize import normalize_name


def register(mcp: FastMCP, ctx: ToolContext) -> None:
    """Register the meal CRUD, item CRUD, alias, and log tools on the MCP server.

    **Inputs:**
    - mcp (FastMCP): The server to attach the tool closures to.
    - ctx (ToolContext): Shared context carrying ``user_key`` and ``tz``.

    **Outputs:**
    - None: Tools are registered as a side effect.
    """
    user_key = ctx.user_key
    tz = ctx.tz

    @mcp.tool
    async def create_meal(
        name: str,
        items: list[MealItemCreate],
        notes: str | None = None,
        aliases: list[str] | None = None,
    ) -> MealResponse:
        """Create a reusable meal with pre-scaled item macros. Each item must specify exactly
        one of `usda_fdc_id` (+ `usda_description`) or `custom_food_id`. Optionally provide
        `aliases` to register alternate phrasings that resolve to this meal.
        """
        payload = MealCreate(name=name, notes=notes, items=items, aliases=list(aliases or []))
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            try:
                async with transaction(session):
                    meal_row, item_rows = await create_meal_with_items(
                        session=session, user_key=user_key, payload=payload, now=now
                    )
            except IntegrityError as exc:
                raise ToolError("Meal name already exists for this user") from exc
            except HTTPException as exc:
                raise ToolError(str(exc.detail)) from exc
        return meal_response(meal_row, item_rows)

    @mcp.tool
    async def list_meals() -> list[MealSummary]:
        """List every saved meal for this user (lightweight summary). Call this early in any
        food-related conversation so you can match user phrasing to a saved meal.
        """
        async with get_session() as session:
            repo = MealsRepository(session)
            rows = await repo.list_meals(user_key)
        return [meal_summary(row) for row in rows]

    @mcp.tool
    async def get_meal(meal_id: str | None = None, name: str | None = None) -> MealResponse:
        """Fetch a meal by id or by name (one is required)."""
        if (meal_id is None) == (name is None):
            raise ToolError("Provide exactly one of meal_id or name")
        async with get_session() as session:
            repo = MealsRepository(session)
            if meal_id is not None:
                try:
                    meal_uuid = UUID(meal_id)
                except ValueError as exc:
                    raise ToolError(f"Invalid meal_id '{meal_id}'") from exc
                meal_row = await repo.get_meal(meal_uuid, user_key)
            else:
                meal_row = await repo.get_meal_by_name(user_key, normalize_name(name or ""))
            if meal_row is None:
                raise ToolError("Meal not found")
            item_rows = await repo.list_items(meal_row["id"])
        return meal_response(meal_row, item_rows)

    @mcp.tool
    async def update_meal(
        meal_id: str,
        name: str | None = None,
        notes: str | None = None,
    ) -> MealResponse:
        """Update meal name and/or notes."""
        try:
            meal_uuid = UUID(meal_id)
        except ValueError as exc:
            raise ToolError(f"Invalid meal_id '{meal_id}'") from exc
        update_payload = MealUpdate(name=name, notes=notes)
        fields = update_payload.model_dump(exclude_unset=True)
        if "name" in fields and fields["name"] is not None:
            fields["normalized_name"] = normalize_name(fields["name"])
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = MealsRepository(session)
            try:
                async with transaction(session):
                    meal_row = await repo.update_meal(meal_uuid, user_key, fields, now)
            except IntegrityError as exc:
                raise ToolError("Meal name already exists for this user") from exc
            if meal_row is None:
                raise ToolError("Meal not found")
            item_rows = await repo.list_items(meal_uuid)
        return meal_response(meal_row, item_rows)

    @mcp.tool
    async def delete_meal(meal_id: str) -> dict[str, bool]:
        """Delete a meal and all its items."""
        try:
            meal_uuid = UUID(meal_id)
        except ValueError as exc:
            raise ToolError(f"Invalid meal_id '{meal_id}'") from exc
        async with get_session() as session:
            repo = MealsRepository(session)
            async with transaction(session):
                deleted = await repo.delete_meal(meal_uuid, user_key)
        return {"deleted": deleted}

    @mcp.tool
    async def add_meal_item(
        meal_id: str,
        item: MealItemCreate,
    ) -> MealItemResponse:
        """Append an item to an existing meal."""
        try:
            meal_uuid = UUID(meal_id)
        except ValueError as exc:
            raise ToolError(f"Invalid meal_id '{meal_id}'") from exc
        if (item.usda_fdc_id is None) == (item.custom_food_id is None):
            raise ToolError("Item must specify exactly one of usda_fdc_id or custom_food_id")
        if item.usda_fdc_id is not None and not item.usda_description:
            raise ToolError("usda_description is required when usda_fdc_id is set")
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = MealsRepository(session)
            async with transaction(session):
                meal_row = await repo.get_meal(meal_uuid, user_key)
                if meal_row is None:
                    raise ToolError("Meal not found")
                if item.custom_food_id is not None:
                    try:
                        await assert_custom_foods_owned(
                            session, user_key, [item.custom_food_id]
                        )
                    except CrossTenantReferenceError as exc:
                        raise ToolError(str(exc)) from exc
                position = await repo.next_position(meal_uuid)
                row = await repo.add_meal_item(
                    meal_id=meal_uuid,
                    position=position,
                    display_name=item.display_name,
                    quantity_text=item.quantity_text,
                    normalized_quantity_value=item.normalized_quantity_value,
                    normalized_quantity_unit=item.normalized_quantity_unit,
                    usda_fdc_id=item.usda_fdc_id,
                    usda_description=item.usda_description,
                    custom_food_id=item.custom_food_id,
                    calories=item.calories,
                    protein_g=item.protein_g,
                    carbs_g=item.carbs_g,
                    fat_g=item.fat_g,
                    now=now,
                )
        return meal_item_response(row)

    @mcp.tool
    async def update_meal_item(
        meal_id: str,
        meal_item_id: str,
        display_name: str | None = None,
        quantity_text: str | None = None,
        normalized_quantity_value: float | None = None,
        normalized_quantity_unit: str | None = None,
        calories: int | None = None,
        protein_g: float | None = None,
        carbs_g: float | None = None,
        fat_g: float | None = None,
    ) -> MealItemResponse:
        """Update an item's mutable fields. The food source (USDA vs custom) cannot be changed
        in place; delete and re-add to switch sources.
        """
        try:
            meal_uuid = UUID(meal_id)
            item_uuid = UUID(meal_item_id)
        except ValueError as exc:
            raise ToolError("Invalid meal_id or meal_item_id") from exc
        fields: dict[str, Any] = {}
        if display_name is not None:
            fields["display_name"] = display_name
        if quantity_text is not None:
            fields["quantity_text"] = quantity_text
        if normalized_quantity_value is not None:
            fields["normalized_quantity_value"] = normalized_quantity_value
        if normalized_quantity_unit is not None:
            fields["normalized_quantity_unit"] = normalized_quantity_unit
        if calories is not None:
            fields["calories"] = calories
        if protein_g is not None:
            fields["protein_g"] = protein_g
        if carbs_g is not None:
            fields["carbs_g"] = carbs_g
        if fat_g is not None:
            fields["fat_g"] = fat_g

        async with get_session() as session:
            repo = MealsRepository(session)
            async with transaction(session):
                meal_row = await repo.get_meal(meal_uuid, user_key)
                if meal_row is None:
                    raise ToolError("Meal not found")
                row = await repo.update_meal_item(item_uuid, meal_uuid, fields)
            if row is None:
                raise ToolError("Meal item not found")
        return meal_item_response(row)

    @mcp.tool
    async def delete_meal_item(meal_id: str, meal_item_id: str) -> dict[str, bool]:
        """Remove one item from a meal."""
        try:
            meal_uuid = UUID(meal_id)
            item_uuid = UUID(meal_item_id)
        except ValueError as exc:
            raise ToolError("Invalid meal_id or meal_item_id") from exc
        async with get_session() as session:
            repo = MealsRepository(session)
            async with transaction(session):
                meal_row = await repo.get_meal(meal_uuid, user_key)
                if meal_row is None:
                    raise ToolError("Meal not found")
                deleted = await repo.delete_meal_item(item_uuid, meal_uuid)
        return {"deleted": deleted}

    @mcp.tool
    async def add_meal_alias(meal_id: str, alias: str) -> MealResponse:
        """Add an alternate phrasing for an existing meal. Looks up by `meal_id` and
        appends a normalized `alias`. Fails when the alias is already used as a canonical
        name or alias by another meal.
        """
        try:
            meal_uuid = UUID(meal_id)
        except ValueError as exc:
            raise ToolError(f"Invalid meal_id '{meal_id}'") from exc
        normalized_alias = normalize_name(alias)
        if not normalized_alias:
            raise ToolError("Alias must be non-empty after normalization")
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = MealsRepository(session)
            async with transaction(session):
                meal_row = await repo.get_meal(meal_uuid, user_key)
                if meal_row is None:
                    raise ToolError("Meal not found")
                if normalized_alias == meal_row["normalized_name"]:
                    item_rows = await repo.list_items(meal_uuid)
                    return meal_response(meal_row, item_rows)
                try:
                    await assert_meal_alias_available(
                        session=session,
                        user_key=user_key,
                        alias=normalized_alias,
                        exclude_meal_id=meal_uuid,
                    )
                except ValueError as exc:
                    raise ToolError(str(exc)) from exc
                updated = await repo.add_alias(
                    meal_id=meal_uuid,
                    user_key=user_key,
                    alias=normalized_alias,
                    now=now,
                )
            if updated is None:
                raise ToolError("Meal not found")
            item_rows = await repo.list_items(meal_uuid)
        return meal_response(updated, item_rows)

    @mcp.tool
    async def remove_meal_alias(meal_id: str, alias: str) -> MealResponse:
        """Remove an alternate phrasing from an existing meal. No-op if absent."""
        try:
            meal_uuid = UUID(meal_id)
        except ValueError as exc:
            raise ToolError(f"Invalid meal_id '{meal_id}'") from exc
        normalized_alias = normalize_name(alias)
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = MealsRepository(session)
            async with transaction(session):
                updated = await repo.remove_alias(
                    meal_id=meal_uuid,
                    user_key=user_key,
                    alias=normalized_alias,
                    now=now,
                )
            if updated is None:
                raise ToolError("Meal not found")
            item_rows = await repo.list_items(meal_uuid)
        return meal_response(updated, item_rows)

    @mcp.tool
    async def log_meal(
        meal_id: str,
        consumed_at: str | None = None,
    ) -> LogMealResponse:
        """Log every item of a saved meal at its original quantity. Items log as separate
        food entries sharing one `entry_group_id`.

        Backdate or future-date by passing `consumed_at`. Accepts either
        `YYYY-MM-DD` (expands to noon of that day in server tz) or a full
        ISO-8601 timestamp. The daily-log bucket is always derived from
        `consumed_at` in server timezone. Defaults to now when omitted.
        """
        try:
            meal_uuid = UUID(meal_id)
        except ValueError as exc:
            raise ToolError(f"Invalid meal_id '{meal_id}'") from exc
        consumed_dt = parse_consumed_at(consumed_at, tz)

        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            try:
                created_rows, day_rows = await log_meal_service(
                    session=session,
                    user_key=user_key,
                    meal_id=meal_uuid,
                    now=now,
                    consumed_at=consumed_dt,
                )
            except HTTPException as exc:
                raise ToolError(str(exc.detail)) from exc

            day_entries = [FoodEntryResponse(**row) for row in day_rows]
            daily_totals = sum_food_entry_macros(day_entries)

            targets_repo = TargetsRepository(session)
            target_row = await targets_repo.get_target_profile(user_key)

        target_obj, remaining = target_and_remaining(target_row, daily_totals)

        return LogMealResponse(
            entries=[FoodEntryResponse(**row) for row in created_rows],
            daily_totals=daily_totals,
            target=target_obj,
            remaining_vs_target=remaining,
        )
