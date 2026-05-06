from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from typing import Any, Literal
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import HTTPException
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import BaseModel, Field
from sqlalchemy.exc import IntegrityError

from nutrition_server.config import get_settings
from nutrition_server.db import get_session, transaction
from nutrition_server.macro_aggregates import sum_food_entry_macros
from nutrition_server.mcp.auth import ApiKeyMiddleware, GitHubAllowlistMiddleware
from nutrition_server.models import (
    CustomFoodCreate,
    CustomFoodResponse,
    CustomFoodUpdate,
    FoodEntryCreate,
    FoodEntryResponse,
    FoodMemoryEntry,
    MacroTargets,
    MacroTotals,
    MealCreate,
    MealItemCreate,
    MealItemResponse,
    MealResponse,
    MealSummary,
    MealUpdate,
    ResolvedFood,
)
from nutrition_server.repositories.custom_foods import CustomFoodsRepository
from nutrition_server.repositories.entries import EntriesRepository
from nutrition_server.repositories.food_memory import FoodMemoryRepository
from nutrition_server.repositories.meals import MealsRepository
from nutrition_server.repositories.targets import TargetsRepository
from nutrition_server.services.custom_foods_service import upsert_custom_food_and_remember
from nutrition_server.services.entries_service import create_entries_with_side_effects
from nutrition_server.services.food_memory_service import resolve_food_by_name
from nutrition_server.services.meals_service import create_meal_with_items, log_meal as log_meal_service
from nutrition_server.services.normalize import normalize_name
from nutrition_server.services.summary_service import build_daily_summary


WORKFLOW_INSTRUCTIONS = """
Nutrition tracking workflow. Follow this order on every food-related interaction:

1) MEALS FIRST. Call `list_meals` once early in the conversation. If anything the user
   says matches a saved meal name (be liberal — "my breakfast", "the wrap", etc.), call
   `log_meal` with that meal_id and stop. Meals log all their ingredients at the original
   quantities; do not scale.

2) MEMORY NEXT. For each individual food the user mentions, call `resolve_food(name)`
   FIRST. If it returns `type != "none"`, use the returned macros and basis to scale to
   the user's quantity, then call `log_food` (passing `fdc_id` for memory_usda hits or
   `custom_food_id` for custom_food hits). Skip `search_food`.

3) USDA SEARCH FALLBACK. Only when memory misses, call `search_food` and pick a candidate.

4) AUTO-REMEMBER ON CORRECTIONS. If the user corrects your USDA pick (different food, or
   you got the macros wrong), after logging the corrected version call `remember_food`
   with the corrected fdc_id, basis, and per-basis macros so this user's next mention of
   the same name resolves directly. For corrections backed by a photo or user-provided
   macros (no USDA equivalent), call `save_custom_food` which auto-remembers.

5) PHOTO / MANUAL MACROS. When the user provides macros directly (via photo or text)
   without a USDA reference, call `save_custom_food` with `basis="per_serving"` (default
   for photo-derived foods) — this creates the custom food and writes memory in one step.
   Then call `log_food` with the returned `custom_food_id`.

`forget_food(name)` and `list_remembered_foods()` let the user audit memory.
""".strip()


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


class LogMealResponse(BaseModel):
    entries: list[FoodEntryResponse]
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


def _custom_food_response(row: dict[str, Any]) -> CustomFoodResponse:
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


def _food_memory_entry(row: dict[str, Any]) -> FoodMemoryEntry:
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
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


def _meal_item_response(row: dict[str, Any]) -> MealItemResponse:
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


def _meal_response(meal_row: dict[str, Any], item_rows: list[dict[str, Any]]) -> MealResponse:
    return MealResponse(
        id=meal_row["id"],
        user_key=meal_row["user_key"],
        name=meal_row["name"],
        normalized_name=meal_row["normalized_name"],
        notes=meal_row["notes"],
        created_at=meal_row["created_at"],
        updated_at=meal_row["updated_at"],
        items=[_meal_item_response(r) for r in item_rows],
    )


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
        mcp = FastMCP(name="nutrition", instructions=WORKFLOW_INSTRUCTIONS, auth=auth_provider)
        if settings.allowed_github_users_set:
            mcp.add_middleware(GitHubAllowlistMiddleware(settings.allowed_github_users_set))
    else:
        mcp = FastMCP(name="nutrition", instructions=WORKFLOW_INSTRUCTIONS)
        mcp.add_middleware(ApiKeyMiddleware(settings.api_key))

    user_key = settings.default_user_key

    # ---------------- core search/log ----------------

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
    ) -> LogFoodResponse:
        """Log a food entry for today (server timezone) with pre-scaled macros.

        Provide EXACTLY ONE source:
        - `fdc_id` + `usda_description` for USDA-backed entries
        - `custom_food_id` (UUID string) for entries backed by a saved custom food

        `calories`/`protein_g`/`carbs_g`/`fat_g` are the FINAL values for the consumed quantity
        (already scaled). `display_name` is the user-facing label; `quantity_text` is the raw phrase.
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
        )
        now = DateTimeValue.now(tz=tz)

        async with get_session() as session:
            created_rows, day_rows = await create_entries_with_side_effects(
                session=session,
                user_key=user_key,
                items=[item],
                now=now,
            )
            day_entries = [FoodEntryResponse(**row) for row in day_rows]
            day_totals = sum_food_entry_macros(day_entries)

            targets_repo = TargetsRepository(session)
            target_row = await targets_repo.get_target_profile(user_key)

        target_obj, remaining = _target_and_remaining(target_row, day_totals)

        return LogFoodResponse(
            entry=FoodEntryResponse(**created_rows[0]),
            day_totals=day_totals,
            target=target_obj,
            remaining_vs_target=remaining,
        )

    @mcp.tool
    async def get_day(date: str | None = None) -> DaySummary:
        """Return entries + totals for `date` (YYYY-MM-DD). Defaults to today."""
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
                    user_key=user_key,
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
                    daily_log_id(user_key, day)
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
        """Delete a food entry by UUID."""
        try:
            entry_uuid = UUID(entry_id)
        except ValueError as exc:
            raise ToolError(f"Invalid entry_id '{entry_id}'") from exc

        async with get_session() as session:
            repo = EntriesRepository(session)
            async with transaction(session):
                deleted = await repo.delete_entry(entry_uuid)
        return {"deleted": deleted}

    # ---------------- targets ----------------

    @mcp.tool
    async def get_targets() -> MacroTargets | None:
        """Return the configured macro targets, or null if none are set."""
        async with get_session() as session:
            repo = TargetsRepository(session)
            row = await repo.get_target_profile(user_key)
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
        """Upsert the macro targets profile."""
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = TargetsRepository(session)
            async with transaction(session):
                await repo.upsert_targets(
                    user_key=user_key,
                    calories=calories,
                    protein_g=protein_g,
                    carbs_g=carbs_g,
                    fat_g=fat_g,
                    updated_at=now,
                )
        return MacroTargets(calories=calories, protein_g=protein_g, carbs_g=carbs_g, fat_g=fat_g)

    # ---------------- custom foods ----------------

    @mcp.tool
    async def save_custom_food(
        name: str,
        basis: Literal["per_100g", "per_serving", "per_unit"],
        calories: int = Field(ge=0),
        protein_g: float = Field(ge=0),
        carbs_g: float = Field(ge=0),
        fat_g: float = Field(ge=0),
        serving_size: float | None = None,
        serving_size_unit: str | None = None,
        source: Literal["manual", "photo", "corrected"] = "manual",
        notes: str | None = None,
    ) -> CustomFoodResponse:
        """Create or update a user-defined food (no USDA equivalent). Also writes food_memory
        so future mentions of `name` resolve to this custom food automatically.

        For photo-derived foods, default `basis="per_serving"` and provide `serving_size`/
        `serving_size_unit` (e.g. 1 / "wrap"). The macros are per the indicated basis.
        """
        payload = CustomFoodCreate(
            name=name,
            basis=basis,
            serving_size=serving_size,
            serving_size_unit=serving_size_unit,
            calories=calories,
            protein_g=protein_g,
            carbs_g=carbs_g,
            fat_g=fat_g,
            source=source,
            notes=notes,
        )
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            async with transaction(session):
                row = await upsert_custom_food_and_remember(
                    session=session, user_key=user_key, payload=payload, now=now
                )
        return _custom_food_response(row)

    @mcp.tool
    async def update_custom_food(
        custom_food_id: str,
        name: str | None = None,
        basis: Literal["per_100g", "per_serving", "per_unit"] | None = None,
        serving_size: float | None = None,
        serving_size_unit: str | None = None,
        calories: int | None = None,
        protein_g: float | None = None,
        carbs_g: float | None = None,
        fat_g: float | None = None,
        source: Literal["manual", "photo", "corrected"] | None = None,
        notes: str | None = None,
    ) -> CustomFoodResponse:
        """Update a subset of fields on a custom food. Existing entries that referenced this
        custom food keep their original macro snapshot; only future logs use the new values.
        """
        try:
            cf_uuid = UUID(custom_food_id)
        except ValueError as exc:
            raise ToolError(f"Invalid custom_food_id '{custom_food_id}'") from exc

        payload = CustomFoodUpdate(
            name=name,
            basis=basis,
            serving_size=serving_size,
            serving_size_unit=serving_size_unit,
            calories=calories,
            protein_g=protein_g,
            carbs_g=carbs_g,
            fat_g=fat_g,
            source=source,
            notes=notes,
        )
        fields = payload.model_dump(exclude_unset=True)
        if "name" in fields and fields["name"] is not None:
            fields["normalized_name"] = normalize_name(fields["name"])

        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = CustomFoodsRepository(session)
            async with transaction(session):
                row = await repo.update_fields(cf_uuid, user_key, fields, now)
        if row is None:
            raise ToolError("Custom food not found")
        return _custom_food_response(row)

    @mcp.tool
    async def delete_custom_food(custom_food_id: str) -> dict[str, bool]:
        """Delete a custom food. Fails if any past food entries or meal items reference it."""
        try:
            cf_uuid = UUID(custom_food_id)
        except ValueError as exc:
            raise ToolError(f"Invalid custom_food_id '{custom_food_id}'") from exc
        async with get_session() as session:
            repo = CustomFoodsRepository(session)
            try:
                async with transaction(session):
                    deleted = await repo.delete(cf_uuid, user_key)
            except IntegrityError as exc:
                raise ToolError(
                    "Custom food is referenced by past entries or meal items; cannot delete"
                ) from exc
        return {"deleted": deleted}

    @mcp.tool
    async def list_custom_foods() -> list[CustomFoodResponse]:
        """List all custom foods for this user."""
        async with get_session() as session:
            repo = CustomFoodsRepository(session)
            rows = await repo.list_for_user(user_key)
        return [_custom_food_response(r) for r in rows]

    # ---------------- food memory ----------------

    @mcp.tool
    async def remember_food(
        name: str,
        fdc_id: int,
        usda_description: str,
        basis: Literal["per_100g", "per_serving", "per_unit"],
        calories: int = Field(ge=0),
        protein_g: float = Field(ge=0),
        carbs_g: float = Field(ge=0),
        fat_g: float = Field(ge=0),
        serving_size: float | None = None,
        serving_size_unit: str | None = None,
    ) -> FoodMemoryEntry:
        """Save a USDA pointer keyed by `name`. Call this AFTER the user corrects your USDA
        choice so future mentions of `name` resolve directly. Macros must be at the indicated
        `basis` (NOT scaled to a previous quantity).

        For custom foods (photo / manual macros), use `save_custom_food` instead — that path
        writes memory automatically.
        """
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = FoodMemoryRepository(session)
            async with transaction(session):
                row = await repo.upsert_usda(
                    user_key=user_key,
                    name=name,
                    normalized_name=normalize_name(name),
                    usda_fdc_id=fdc_id,
                    usda_description=usda_description,
                    basis=basis,
                    serving_size=serving_size,
                    serving_size_unit=serving_size_unit,
                    calories=calories,
                    protein_g=protein_g,
                    carbs_g=carbs_g,
                    fat_g=fat_g,
                    now=now,
                )
        return _food_memory_entry(row)

    @mcp.tool
    async def forget_food(name: str) -> dict[str, bool]:
        """Delete the memory entry for `name`. Custom foods themselves are not deleted."""
        async with get_session() as session:
            repo = FoodMemoryRepository(session)
            async with transaction(session):
                deleted = await repo.delete_by_name(user_key, normalize_name(name))
        return {"deleted": deleted}

    @mcp.tool
    async def list_remembered_foods() -> list[FoodMemoryEntry]:
        """List every name → food mapping saved for this user."""
        async with get_session() as session:
            repo = FoodMemoryRepository(session)
            rows = await repo.list_for_user(user_key)
        return [_food_memory_entry(r) for r in rows]

    # ---------------- meals ----------------

    @mcp.tool
    async def create_meal(
        name: str,
        items: list[MealItemCreate],
        notes: str | None = None,
    ) -> MealResponse:
        """Create a reusable meal with pre-scaled item macros. Each item must specify exactly
        one of `usda_fdc_id` (+ `usda_description`) or `custom_food_id`.
        """
        payload = MealCreate(name=name, notes=notes, items=items)
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            try:
                async with transaction(session):
                    meal_row, item_rows = await create_meal_with_items(
                        session=session, user_key=user_key, payload=payload, now=now
                    )
            except IntegrityError as exc:
                raise ToolError("Meal name already exists for this user") from exc
        return _meal_response(meal_row, item_rows)

    @mcp.tool
    async def list_meals() -> list[MealSummary]:
        """List every saved meal for this user (lightweight summary). Call this early in any
        food-related conversation so you can match user phrasing to a saved meal.
        """
        async with get_session() as session:
            repo = MealsRepository(session)
            rows = await repo.list_meals(user_key)
        return [
            MealSummary(
                id=row["id"],
                name=row["name"],
                normalized_name=row["normalized_name"],
                notes=row["notes"],
                item_count=int(row["item_count"]),
            )
            for row in rows
        ]

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
        return _meal_response(meal_row, item_rows)

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
        return _meal_response(meal_row, item_rows)

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
        return _meal_item_response(row)

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
        return _meal_item_response(row)

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
    async def log_meal(
        meal_id: str,
        consumed_at: str | None = None,
    ) -> LogMealResponse:
        """Log every item of a saved meal at its original quantity. Items log as separate
        food entries sharing one `entry_group_id`. `consumed_at` defaults to now (server tz)
        and accepts ISO-8601.
        """
        try:
            meal_uuid = UUID(meal_id)
        except ValueError as exc:
            raise ToolError(f"Invalid meal_id '{meal_id}'") from exc
        consumed_dt: DateTimeValue | None = None
        if consumed_at is not None:
            try:
                consumed_dt = DateTimeValue.fromisoformat(consumed_at)
            except ValueError as exc:
                raise ToolError(f"Invalid consumed_at '{consumed_at}'") from exc
            if consumed_dt.tzinfo is None:
                consumed_dt = consumed_dt.replace(tzinfo=tz)

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
            day_totals = sum_food_entry_macros(day_entries)

            targets_repo = TargetsRepository(session)
            target_row = await targets_repo.get_target_profile(user_key)

        target_obj, remaining = _target_and_remaining(target_row, day_totals)

        return LogMealResponse(
            entries=[FoodEntryResponse(**row) for row in created_rows],
            day_totals=day_totals,
            target=target_obj,
            remaining_vs_target=remaining,
        )

    return mcp


def _target_and_remaining(
    target_row: dict[str, Any] | None,
    day_totals: MacroTotals,
) -> tuple[MacroTargets | None, MacroTotals | None]:
    if target_row is None:
        return None, None
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
    return target_obj, remaining
