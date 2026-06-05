"""MCP tools for USDA search and individual food-entry logging.

Registers ``search_food`` (USDA fallback), ``resolve_food`` (memory lookup),
``log_food`` (log one pre-scaled entry with optional backdating), and
``delete_entry``. These mirror the REST entries/USDA surface and share the
single-tenant ``user_key`` carried by the :class:`ToolContext`.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from uuid import UUID

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import Field

from pulse_server.db import get_session, transaction
from pulse_server.macro_aggregates import sum_food_entry_macros
from pulse_server.mcp.context import ToolContext, basis_for, parse_consumed_at, target_and_remaining
from pulse_server.mcp.models import FoodCandidate, LogFoodResponse, SearchFoodResponse
from pulse_server.models import FoodEntryCreate, FoodEntryResponse, ResolvedFood
from pulse_server.repositories.entries import EntriesRepository
from pulse_server.repositories.targets import TargetsRepository
from pulse_server.services.custom_foods_service import CrossTenantReferenceError
from pulse_server.services.entries_service import create_entries_with_side_effects
from pulse_server.services.food_memory_service import resolve_food_by_name


def register(mcp: FastMCP, ctx: ToolContext) -> None:
    """Register the food-search and food-logging tools on the MCP server.

    **Inputs:**
    - mcp (FastMCP): The server to attach the tool closures to.
    - ctx (ToolContext): Shared context carrying ``user_key``, ``tz``, and the
      lazy ``usda_getter``.

    **Outputs:**
    - None: Tools are registered as a side effect.
    """
    user_key = ctx.user_key
    tz = ctx.tz
    usda_getter = ctx.usda_getter

    @mcp.tool
    async def search_food(
        description: str,
        limit: int = Field(default=3, ge=1, le=10),
    ) -> SearchFoodResponse:
        """Search USDA FoodData Central. Use ONLY after `resolve_food` returns `type=none`.

        Each candidate's macros are at the basis given by `basis` (`per_100g` or `per_serving`).
        Scale them yourself, then call `log_food`.
        """
        usda = usda_getter()
        results = await usda.search(description, page_size=limit)
        candidates = [
            FoodCandidate(
                fdc_id=int(food["fdc_id"]),
                description=str(food["description"]),
                basis=basis_for(food),
                serving_size=food.get("serving_size"),
                serving_size_unit=food.get("serving_size_unit"),
                calories=int(food.get("calories") or 0),
                protein_g=float(food.get("protein_g") or 0.0),
                carbs_g=float(food.get("carbs_g") or 0.0),
                fat_g=float(food.get("fat_g") or 0.0),
            )
            for food in results
        ]
        return SearchFoodResponse(query=description, candidates=candidates)

    @mcp.tool
    async def resolve_food(name: str) -> ResolvedFood:
        """Look up a food name in this user's memory before searching USDA.

        Returns `type="memory_usda"` (with cached fdc_id, basis, and per-basis macros),
        `type="custom_food"` (with the linked custom food's basis and macros), or
        `type="none"` when no memory exists. Always call this before `search_food`.
        """
        async with get_session() as session:
            return await resolve_food_by_name(session=session, user_key=user_key, name=name)

    @mcp.tool
    async def log_food(
        display_name: str,
        quantity_text: str,
        calories: int = Field(ge=0),
        protein_g: float = Field(ge=0),
        carbs_g: float = Field(ge=0),
        fat_g: float = Field(ge=0),
        fdc_id: int | None = None,
        usda_description: str | None = None,
        custom_food_id: str | None = None,
        normalized_quantity_value: float | None = None,
        normalized_quantity_unit: str | None = None,
        consumed_at: str | None = None,
    ) -> LogFoodResponse:
        """Log a food entry with pre-scaled macros. Defaults to now (server timezone).

        Provide EXACTLY ONE source:
        - `fdc_id` + `usda_description` for USDA-backed entries
        - `custom_food_id` (UUID string) for entries backed by a saved custom food

        `calories`/`protein_g`/`carbs_g`/`fat_g` are the FINAL values for the consumed quantity
        (already scaled). `display_name` is the user-facing label; `quantity_text` is
        the raw phrase.

        Backdate or future-date by passing `consumed_at`. Accepts either
        `YYYY-MM-DD` (expands to noon of that day in server tz) or a full
        ISO-8601 timestamp (`2026-05-20T19:30:00-04:00`). The daily-log bucket
        is always derived from `consumed_at` in server timezone — past, present,
        and future dates are all allowed.
        """
        if (fdc_id is None) == (custom_food_id is None):
            raise ToolError("Provide exactly one of fdc_id or custom_food_id")
        if fdc_id is not None and not usda_description:
            raise ToolError("usda_description is required when fdc_id is set")

        custom_food_uuid: UUID | None = None
        if custom_food_id is not None:
            try:
                custom_food_uuid = UUID(custom_food_id)
            except ValueError as exc:
                raise ToolError(f"Invalid custom_food_id '{custom_food_id}'") from exc

        consumed_dt = parse_consumed_at(consumed_at, tz)

        item = FoodEntryCreate(
            display_name=display_name,
            quantity_text=quantity_text,
            normalized_quantity_value=normalized_quantity_value,
            normalized_quantity_unit=normalized_quantity_unit,
            usda_fdc_id=fdc_id,
            usda_description=usda_description,
            custom_food_id=custom_food_uuid,
            calories=calories,
            protein_g=protein_g,
            carbs_g=carbs_g,
            fat_g=fat_g,
            consumed_at=consumed_dt,
        )
        now = DateTimeValue.now(tz=tz)

        async with get_session() as session:
            try:
                created_rows, day_rows = await create_entries_with_side_effects(
                    session=session,
                    user_key=user_key,
                    items=[item],
                    now=now,
                )
            except CrossTenantReferenceError as exc:
                raise ToolError(str(exc)) from exc
            day_entries = [FoodEntryResponse(**row) for row in day_rows]
            daily_totals = sum_food_entry_macros(day_entries)

            targets_repo = TargetsRepository(session)
            target_row = await targets_repo.get_target_profile(user_key)

        target_obj, remaining = target_and_remaining(target_row, daily_totals)

        return LogFoodResponse(
            entry=FoodEntryResponse(**created_rows[0]),
            daily_totals=daily_totals,
            target=target_obj,
            remaining_vs_target=remaining,
        )

    @mcp.tool
    async def delete_entry(entry_id: str) -> dict[str, bool]:
        """Delete a food entry by UUID."""
        try:
            entry_uuid = UUID(entry_id)
        except ValueError as exc:
            raise ToolError(f"Invalid entry_id '{entry_id}'") from exc

        async with get_session() as session:
            repo = EntriesRepository(session)
            async with transaction(session):
                deleted = await repo.delete_entry(entry_uuid, user_key)
        return {"deleted": deleted}
