from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import HTTPException
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import BaseModel, Field

from nutrition_server.config import get_settings
from nutrition_server.db import get_session, transaction
from nutrition_server.macro_aggregates import sum_food_entry_macros
from nutrition_server.mcp.auth import ApiKeyMiddleware, GitHubAllowlistMiddleware
from nutrition_server.models import FoodEntryCreate, FoodEntryResponse, MacroTargets, MacroTotals
from nutrition_server.repositories.entries import EntriesRepository
from nutrition_server.repositories.targets import TargetsRepository
from nutrition_server.services.entries_service import create_entries_with_side_effects
from nutrition_server.services.summary_service import build_daily_summary


class FoodCandidate(BaseModel):
    fdc_id: int
    description: str
    basis: str  # "per_100g" or "per_serving"
    serving_size: float | None
    serving_size_unit: str | None
    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float


class SearchFoodResponse(BaseModel):
    query: str
    candidates: list[FoodCandidate]
    note: str = (
        "Macros are reported on the basis indicated by `basis`. "
        "Scale them yourself for the user's quantity, then call `log_food` with the final "
        "calories/protein_g/carbs_g/fat_g."
    )


class LogFoodResponse(BaseModel):
    entry: FoodEntryResponse
    day_totals: MacroTotals
    target: MacroTargets | None = None
    remaining_vs_target: MacroTotals | None = None


class DaySummary(BaseModel):
    date: DateValue
    target: MacroTargets | None
    consumed: MacroTotals
    remaining: MacroTotals | None
    entries: list[FoodEntryResponse]


def _basis_for(food: dict[str, Any]) -> str:
    return "per_serving" if food.get("serving_size") else "per_100g"


def build_mcp(usda_getter) -> FastMCP:
    """Construct the FastMCP server. `usda_getter` is a callable returning the live USDAClient.

    Indirection lets callers bind to `app.get_usda_client` after lifespan startup without import cycles.

    Auth: GitHubProvider when GITHUB_CLIENT_ID/SECRET + PUBLIC_BASE_URL are set (claude.ai connector
    requires OAuth + DCR). Otherwise falls back to X-API-Key middleware for local dev / curl.
    """
    settings = get_settings()
    tz = ZoneInfo(settings.timezone)

    if settings.oauth_enabled:
        from fastmcp.server.auth.providers.github import GitHubProvider

        auth_provider = GitHubProvider(
            client_id=settings.github_client_id,
            client_secret=settings.github_client_secret,
            base_url=settings.public_base_url.rstrip("/"),
        )
        mcp = FastMCP(name="nutrition", auth=auth_provider)
        if settings.allowed_github_users_set:
            mcp.add_middleware(GitHubAllowlistMiddleware(settings.allowed_github_users_set))
    else:
        mcp = FastMCP(name="nutrition")
        mcp.add_middleware(ApiKeyMiddleware(settings.api_key))

    @mcp.tool
    async def search_food(
        description: str,
        limit: int = Field(default=3, ge=1, le=10),
    ) -> SearchFoodResponse:
        """Search USDA FoodData Central for foods matching `description`.

        Returns up to `limit` candidates (default 3). Each candidate's macros are reported on the
        basis given by `basis`:
        - `per_100g` → calories/macros are per 100 grams (USDA SR Legacy / Foundation foods)
        - `per_serving` → calories/macros are per `serving_size` `serving_size_unit` (Branded foods)

        You (the model) are responsible for parsing the user's free-text quantity and scaling these
        macros yourself, then passing the final values to `log_food`. The server stores what you
        send and does not re-scale.
        """
        usda = usda_getter()
        results = await usda.search(description, page_size=limit)
        candidates = [
            FoodCandidate(
                fdc_id=int(food["fdc_id"]),
                description=str(food["description"]),
                basis=_basis_for(food),
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
    async def log_food(
        fdc_id: int,
        usda_description: str,
        display_name: str,
        quantity_text: str,
        calories: int = Field(ge=0),
        protein_g: float = Field(ge=0),
        carbs_g: float = Field(ge=0),
        fat_g: float = Field(ge=0),
        normalized_quantity_value: float | None = None,
        normalized_quantity_unit: str | None = None,
    ) -> LogFoodResponse:
        """Log a food entry for today (server timezone) with pre-scaled macros.

        Pass values you computed from a prior `search_food` result:
        - `fdc_id` and `usda_description` from the chosen candidate (immutable receipt)
        - `display_name` is the user-facing label (you can rewrite USDA's verbose description)
        - `quantity_text` is the user's original phrasing ("150g", "1 wrap", "2 cups")
        - `calories` / `protein_g` / `carbs_g` / `fat_g` are the FINAL values for the consumed
          quantity — already scaled from the basis returned by `search_food`
        - `normalized_quantity_value` / `_unit` are optional structured forms when the quantity is
          gram-convertible (helps later analytics)
        """
        item = FoodEntryCreate(
            display_name=display_name,
            quantity_text=quantity_text,
            normalized_quantity_value=normalized_quantity_value,
            normalized_quantity_unit=normalized_quantity_unit,
            usda_fdc_id=fdc_id,
            usda_description=usda_description,
            calories=calories,
            protein_g=protein_g,
            carbs_g=carbs_g,
            fat_g=fat_g,
        )
        now = DateTimeValue.now(tz=tz)

        async with get_session() as session:
            created_rows, day_rows = await create_entries_with_side_effects(
                session=session,
                user_key=settings.default_user_key,
                items=[item],
                now=now,
            )
            day_entries = [FoodEntryResponse(**row) for row in day_rows]
            day_totals = sum_food_entry_macros(day_entries)

            targets_repo = TargetsRepository(session)
            target_row = await targets_repo.get_target_profile(settings.default_user_key)

        target_obj: MacroTargets | None = None
        remaining: MacroTotals | None = None
        if target_row is not None:
            target_obj = MacroTargets(
                calories=int(target_row["calories_target"]),
                protein_g=float(target_row["protein_g_target"]),
                carbs_g=float(target_row["carbs_g_target"]),
                fat_g=float(target_row["fat_g_target"]),
            )
            remaining = MacroTotals(
                calories=target_obj.calories - day_totals.calories,
                protein_g=round(target_obj.protein_g - day_totals.protein_g, 1),
                carbs_g=round(target_obj.carbs_g - day_totals.carbs_g, 1),
                fat_g=round(target_obj.fat_g - day_totals.fat_g, 1),
            )

        return LogFoodResponse(
            entry=FoodEntryResponse(**created_rows[0]),
            day_totals=day_totals,
            target=target_obj,
            remaining_vs_target=remaining,
        )

    @mcp.tool
    async def get_day(date: str | None = None) -> DaySummary:
        """Return entries + totals for `date` (YYYY-MM-DD). Defaults to today in server timezone.

        Returns null target/remaining when no targets are configured (call `set_targets` first).
        """
        if date is None:
            day = DateTimeValue.now(tz=tz).date()
        else:
            try:
                day = DateValue.fromisoformat(date)
            except ValueError as exc:
                raise ToolError(f"Invalid date '{date}', expected YYYY-MM-DD") from exc

        async with get_session() as session:
            try:
                summary = await build_daily_summary(
                    session=session,
                    user_key=settings.default_user_key,
                    summary_date=day,
                )
                return DaySummary(
                    date=summary.date,
                    target=summary.target,
                    consumed=summary.consumed,
                    remaining=summary.remaining,
                    entries=summary.entries,
                )
            except HTTPException as exc:
                if exc.status_code != 404:
                    raise
                from nutrition_server.services.log_ids import daily_log_id

                entries_repo = EntriesRepository(session)
                rows = await entries_repo.list_entries_by_daily_log_id(
                    daily_log_id(settings.default_user_key, day)
                )
                entries = [FoodEntryResponse(**row) for row in rows]
                return DaySummary(
                    date=day,
                    target=None,
                    consumed=sum_food_entry_macros(entries),
                    remaining=None,
                    entries=entries,
                )

    @mcp.tool
    async def delete_entry(entry_id: str) -> dict[str, bool]:
        """Delete a food entry by UUID. Returns {"deleted": true|false}."""
        try:
            entry_uuid = UUID(entry_id)
        except ValueError as exc:
            raise ToolError(f"Invalid entry_id '{entry_id}'") from exc

        async with get_session() as session:
            repo = EntriesRepository(session)
            async with transaction(session):
                deleted = await repo.delete_entry(entry_uuid)
        return {"deleted": deleted}

    @mcp.tool
    async def get_targets() -> MacroTargets | None:
        """Return the configured macro targets, or null if none are set."""
        async with get_session() as session:
            repo = TargetsRepository(session)
            row = await repo.get_target_profile(settings.default_user_key)
        if row is None:
            return None
        return MacroTargets(
            calories=int(row["calories_target"]),
            protein_g=float(row["protein_g_target"]),
            carbs_g=float(row["carbs_g_target"]),
            fat_g=float(row["fat_g_target"]),
        )

    @mcp.tool
    async def set_targets(
        calories: int = Field(gt=0),
        protein_g: float = Field(ge=0),
        carbs_g: float = Field(ge=0),
        fat_g: float = Field(ge=0),
    ) -> MacroTargets:
        """Upsert the macro targets profile. Targets seldom change; call when starting or revising."""
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = TargetsRepository(session)
            async with transaction(session):
                await repo.upsert_targets(
                    user_key=settings.default_user_key,
                    calories=calories,
                    protein_g=protein_g,
                    carbs_g=carbs_g,
                    fat_g=fat_g,
                    updated_at=now,
                )
        return MacroTargets(calories=calories, protein_g=protein_g, carbs_g=carbs_g, fat_g=fat_g)

    return mcp
