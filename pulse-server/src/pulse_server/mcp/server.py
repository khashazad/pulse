"""FastMCP server definition exposing diet-tracking tools to MCP clients.

Provides :func:`build_mcp`, the factory that wires up the ``FastMCP`` instance
with optional GitHub-OAuth authentication and a complete suite of tools:
USDA-backed food search and logging, food-memory (per-user name → food
mapping), custom foods, meal-prep containers, reusable meals (create / log /
alias / item CRUD), macro targets, and day summaries. Also defines the Pydantic
request/response models that shape the wire format
(``FoodCandidate``, ``SearchFoodResponse``, ``LogFoodResponse``,
``LogMealResponse``, ``DaySummary``) and the row→model adapters
(``_container_response``, ``_custom_food_response``, ``_food_memory_entry``,
``_meal_item_response``, ``_meal_response``) used by those tools.

Sits at the top of the MCP layer: it pulls in repositories under
``repositories/`` and orchestration services under ``services/`` so the MCP
surface mirrors the REST surface and shares the same single-tenant
``LEGACY_USER_KEY`` data. The ``WORKFLOW_INSTRUCTIONS`` constant is the prompt
the FastMCP server ships to clients describing the canonical food-logging
workflow.
"""

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

from pulse_server.config import SERVICE_TOKEN_LOGIN, get_settings
from pulse_server.db import get_session, transaction
from pulse_server.macro_aggregates import sum_food_entry_macros
from pulse_server.mcp.auth import GitHubAllowlistMiddleware
from pulse_server.models import (
    ContainerResponse,
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
from pulse_server.repositories.containers import ContainersRepository
from pulse_server.repositories.custom_foods import CustomFoodsRepository
from pulse_server.repositories.entries import EntriesRepository
from pulse_server.repositories.food_memory import FoodMemoryRepository
from pulse_server.repositories.meals import MealsRepository
from pulse_server.repositories.targets import TargetsRepository
from pulse_server.services.custom_foods_service import upsert_custom_food_and_remember
from pulse_server.services.entries_service import create_entries_with_side_effects
from pulse_server.services.food_memory_service import (
    assert_food_alias_available,
    normalize_alias_list,
    resolve_food_by_name,
)
from pulse_server.services.meals_service import (
    assert_meal_alias_available,
    create_meal_with_items,
    log_meal as log_meal_service,
    normalize_alias_list as normalize_meal_alias_list,
)
from pulse_server.services.normalize import normalize_name
from pulse_server.services.summary_service import build_daily_summary


WORKFLOW_INSTRUCTIONS = """
Diet tracking workflow. Follow this order on every food-related interaction:

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

5) AUTO-ALIAS ON NAME DRIFT. When the user refers to an existing memory entry or saved
   meal under a phrasing that didn't exact-match (you matched it from `list_meals` /
   `list_remembered_foods` context, not from `resolve_food` / `get_meal` returning it
   directly), call `add_meal_alias` or `add_food_alias` with the user's phrasing after
   logging. Skip if the phrasing is generic ("breakfast", "lunch", "the usual") or if
   the user explicitly disambiguated this turn. Skip if you're not confident the
   phrasing should always map to the same entity.

6) PHOTO / MANUAL MACROS. When the user provides macros directly (via photo or text)
   without a USDA reference, call `save_custom_food` with `basis="per_serving"` (default
   for photo-derived foods) — this creates the custom food and writes memory in one step.
   Then call `log_food` with the returned `custom_food_id`.

7) BACKDATE / FUTURE-DATE. `log_food` and `log_meal` accept a single optional
   `consumed_at` for non-today logging. Pass `YYYY-MM-DD` for a date-only ("tomorrow's
   breakfast", "Wednesday's lunch") — the server expands it to noon of that day. Pass
   a full ISO-8601 timestamp when the user gives an explicit time. Without `consumed_at`
   the entry stamps now. Resolve relative dates ("tomorrow", "Wednesday") to absolute
   YYYY-MM-DD before calling. Past, present, and future days are all allowed.

8) EDIT / DELETE ON ANY DAY. `delete_entry(entry_id)` is date-agnostic — the UUID
   already identifies the row regardless of when it was logged. To act on a past or
   future day, call `get_day(date)` first to discover the entry's id, then pass it to
   `delete_entry`. Same pattern for "replace yesterday's eggs": `get_day` → `delete_entry`
   → `log_food(..., consumed_at="<that day>")`.

`forget_food(name)` and `list_remembered_foods()` let the user audit memory.
""".strip()


class FoodCandidate(BaseModel):
    """One USDA search hit returned to the MCP client.

    Carries the macros at the basis (``per_100g`` or ``per_serving``) indicated
    by ``basis``; the client must scale to the user's quantity before logging.
    """

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
    """Envelope for ``search_food`` results: the echoed query plus candidates.

    The ``note`` field is a fixed reminder to the caller that macros are at the
    candidate's basis and must be scaled before logging.
    """

    query: str
    candidates: list[FoodCandidate]
    note: str = (
        "Macros are reported on the basis indicated by `basis`. "
        "Scale them yourself for the user's quantity, then call `log_food` with the final "
        "calories/protein_g/carbs_g/fat_g."
    )


class LogFoodResponse(BaseModel):
    """Result of logging a single food entry.

    Returns the new entry, today's running totals, and (when targets are set)
    the user's target profile plus remaining macros for the day.
    """

    entry: FoodEntryResponse
    day_totals: MacroTotals
    target: MacroTargets | None = None
    remaining_vs_target: MacroTotals | None = None


class LogMealResponse(BaseModel):
    """Result of logging a saved meal (one food entry per item).

    Mirrors :class:`LogFoodResponse` but carries the list of entries created
    from the meal's items.
    """

    entries: list[FoodEntryResponse]
    day_totals: MacroTotals
    target: MacroTargets | None = None
    remaining_vs_target: MacroTotals | None = None


class DaySummary(BaseModel):
    """Per-day summary returned by ``get_day``.

    Bundles the date, target profile (if any), consumed macros, remaining
    macros vs. target (if any), and all food entries for that day.
    """

    date: DateValue
    target: MacroTargets | None
    consumed: MacroTotals
    remaining: MacroTotals | None
    entries: list[FoodEntryResponse]


def _basis_for(food: dict[str, Any]) -> str:
    """Infer the macro basis label for a USDA search row.

    **Inputs:**
    - food (dict[str, Any]): Normalized USDA food row.

    **Outputs:**
    - str: ``"per_serving"`` when the row carries a ``serving_size``,
      otherwise ``"per_100g"``.
    """
    return "per_serving" if food.get("serving_size") else "per_100g"


def _container_response(row: dict[str, Any]) -> ContainerResponse:
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


def _custom_food_response(row: dict[str, Any]) -> CustomFoodResponse:
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


def _food_memory_entry(row: dict[str, Any]) -> FoodMemoryEntry:
    """Adapt a ``food_memory`` repository row to its wire DTO.

    **Inputs:**
    - row (dict[str, Any]): Column→value mapping from ``FoodMemoryRepository``.

    **Outputs:**
    - FoodMemoryEntry: Pydantic model with numerics coerced and any nullable
      column passed through as ``None``.
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


def _meal_item_response(row: dict[str, Any]) -> MealItemResponse:
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


def _meal_response(meal_row: dict[str, Any], item_rows: list[dict[str, Any]]) -> MealResponse:
    """Combine a meal row and its item rows into a wire DTO.

    **Inputs:**
    - meal_row (dict[str, Any]): Column→value mapping for the parent meal.
    - item_rows (list[dict[str, Any]]): Column→value mappings for each meal item,
      already ordered by position.

    **Outputs:**
    - MealResponse: Pydantic model with each item adapted via
      :func:`_meal_item_response`.
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
        items=[_meal_item_response(r) for r in item_rows],
    )


def _build_static_token_verifier(service_token: str):
    """Build a fastmcp ``StaticTokenVerifier`` for the configured service token.

    Synthesizes a GitHub-style ``login`` claim equal to
    :data:`SERVICE_TOKEN_LOGIN` so :class:`GitHubAllowlistMiddleware` can gate
    service-token calls with the same machinery as real GitHub OAuth users.

    **Inputs:**
    - service_token (str): The shared secret accepted as a bearer token.

    **Outputs:**
    - StaticTokenVerifier: Verifier mapping the token to a single client
      identity carrying the service login claim.
    """
    from fastmcp.server.auth.providers.jwt import StaticTokenVerifier

    # MultiAuth inherits required_scopes from GitHubProvider (defaults to ["user"])
    # and enforces them on every verified token regardless of source. The service
    # token represents a fully-authorized principal, so mirror the GitHub scope
    # to clear the global check.
    return StaticTokenVerifier(
        tokens={
            service_token: {
                "client_id": SERVICE_TOKEN_LOGIN,
                "scopes": ["user"],
                "login": SERVICE_TOKEN_LOGIN,
            }
        }
    )


def _build_auth_provider(settings):
    """Assemble the MCP auth provider from configured GitHub OAuth and/or service token.

    Combinations:

    - GitHub OAuth only → ``GitHubProvider`` directly.
    - Service token only → ``StaticTokenVerifier`` directly (no OAuth metadata routes).
    - Both → ``MultiAuth`` with GitHub as the server (owning routes/metadata) and the
      static verifier as a fallback verifier.
    - Neither → ``None``; the caller decides whether unauth is permitted.

    **Inputs:**
    - settings (Settings): Application settings carrying both auth configurations.

    **Outputs:**
    - AuthProvider | None: Configured provider, or ``None`` when no auth is set.
    """
    static_verifier = (
        _build_static_token_verifier(settings.mcp_service_token)
        if settings.mcp_service_token_enabled
        else None
    )

    if settings.mcp_oauth_enabled:
        from fastmcp.server.auth.providers.github import GitHubProvider

        github_provider = GitHubProvider(
            client_id=settings.github_client_id,
            client_secret=settings.github_client_secret,
            base_url=settings.public_base_url.rstrip("/"),
        )
        if static_verifier is None:
            return github_provider
        from fastmcp.server.auth import MultiAuth

        return MultiAuth(server=github_provider, verifiers=[static_verifier])

    return static_verifier


def build_mcp(usda_getter) -> FastMCP:
    """Construct the FastMCP server and register every diet-tracking tool.

    Indirection through ``usda_getter`` lets callers bind to
    ``app.get_usda_client`` after lifespan startup without import cycles. The
    auth provider is assembled by :func:`_build_auth_provider` from any
    combination of GitHub OAuth (``GITHUB_CLIENT_ID``/``SECRET`` +
    ``PUBLIC_BASE_URL``) and a static service token (``MCP_SERVICE_TOKEN``).
    :class:`GitHubAllowlistMiddleware` runs when ``ALLOWED_GITHUB_USERS`` is
    non-empty; the service-token synthetic login is auto-included in that
    allowlist. With no auth configured the server is refused outside local env
    unless ``MCP_ALLOW_UNAUTH=true``.

    **Inputs:**
    - usda_getter: Zero-arg callable returning the live ``USDAClient``;
      consulted lazily inside the ``search_food`` tool.

    **Outputs:**
    - FastMCP: Fully wired MCP server with all food/meal/target/container tools
      registered, ready to be mounted by ``app.py``.

    **Exceptions:**
    - RuntimeError: Refused to build an unauthenticated MCP outside local env
      when ``MCP_ALLOW_UNAUTH`` is not set (belt-and-suspenders guard for
      callers that bypass Settings validation).
    """
    settings = get_settings()
    tz = ZoneInfo(settings.timezone)

    auth_provider = _build_auth_provider(settings)
    if auth_provider is not None:
        mcp = FastMCP(name="diet", instructions=WORKFLOW_INSTRUCTIONS, auth=auth_provider)
        if settings.allowed_github_users_set:
            mcp.add_middleware(GitHubAllowlistMiddleware(settings.allowed_github_users_set))
    else:
        # Settings.model_validator already rejects this combo outside local; this is a
        # belt-and-suspenders guard for callers that bypass Settings (e.g. tests).
        if not settings.is_local_env and not settings.mcp_allow_unauth:
            raise RuntimeError(
                "Refusing to build unauthenticated MCP outside local env. "
                "Set GITHUB_CLIENT_ID/SECRET + PUBLIC_BASE_URL, MCP_SERVICE_TOKEN, "
                "or MCP_ALLOW_UNAUTH=true."
            )
        mcp = FastMCP(name="diet", instructions=WORKFLOW_INSTRUCTIONS)

    # Match REST surface so data created via either path lives in the same tenant.
    user_key = settings.legacy_user_key

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
        consumed_at: str | None = None,
    ) -> LogFoodResponse:
        """Log a food entry with pre-scaled macros. Defaults to now (server timezone).

        Provide EXACTLY ONE source:
        - `fdc_id` + `usda_description` for USDA-backed entries
        - `custom_food_id` (UUID string) for entries backed by a saved custom food

        `calories`/`protein_g`/`carbs_g`/`fat_g` are the FINAL values for the consumed quantity
        (already scaled). `display_name` is the user-facing label; `quantity_text` is the raw phrase.

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

        consumed_dt = _parse_consumed_at(consumed_at, tz)

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
                from pulse_server.services.log_ids import daily_log_id

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
                deleted = await repo.delete_entry(entry_uuid, user_key)
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

    # ---------------- containers ----------------

    @mcp.tool
    async def list_containers() -> list[ContainerResponse]:
        """List all meal-prep containers (pots, boxes) saved for this user. Each row
        carries `tare_weight_g`, the container's empty weight in grams, used to deduct
        from a scale reading when meal-prepping."""
        async with get_session() as session:
            repo = ContainersRepository(session)
            rows = await repo.list_for_user(user_key)
        return [_container_response(r) for r in rows]

    @mcp.tool
    async def save_container(
        name: str,
        tare_weight_g: float = Field(gt=0),
    ) -> ContainerResponse:
        """Create a new meal-prep container with its empty (tare) weight in grams.
        Use this when the user mentions a new pot/box they want to track."""
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = ContainersRepository(session)
            try:
                async with transaction(session):
                    row = await repo.create(
                        user_key=user_key,
                        name=name,
                        normalized_name=normalize_name(name),
                        tare_weight_g=tare_weight_g,
                        now=now,
                    )
            except IntegrityError as exc:
                raise ToolError("A container with that name already exists") from exc
        return _container_response(row)

    @mcp.tool
    async def update_container(
        container_id: str,
        name: str | None = None,
        tare_weight_g: float | None = Field(default=None, gt=0),
    ) -> ContainerResponse:
        """Update name and/or tare weight of an existing container."""
        try:
            cid = UUID(container_id)
        except ValueError as exc:
            raise ToolError("container_id must be a UUID") from exc
        fields: dict[str, Any] = {}
        if name is not None:
            fields["name"] = name
            fields["normalized_name"] = normalize_name(name)
        if tare_weight_g is not None:
            fields["tare_weight_g"] = tare_weight_g
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = ContainersRepository(session)
            try:
                async with transaction(session):
                    row = await repo.update_fields(cid, user_key, fields, now)
            except IntegrityError as exc:
                raise ToolError("A container with that name already exists") from exc
        if row is None:
            raise ToolError("Container not found")
        return _container_response(row)

    @mcp.tool
    async def delete_container(container_id: str) -> dict[str, bool]:
        """Delete a container by id."""
        try:
            cid = UUID(container_id)
        except ValueError as exc:
            raise ToolError("container_id must be a UUID") from exc
        async with get_session() as session:
            repo = ContainersRepository(session)
            async with transaction(session):
                deleted = await repo.delete(cid, user_key)
        return {"deleted": deleted}

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
        aliases: list[str] | None = None,
    ) -> FoodMemoryEntry:
        """Save a USDA pointer keyed by `name`. Optionally provide `aliases` (additional
        phrasings that should resolve to the same entry). Macros must be at the indicated
        `basis` (NOT scaled to a previous quantity).
        """
        now = DateTimeValue.now(tz=tz)
        normalized = normalize_name(name)
        cleaned_aliases: list[str] | None = None
        if aliases is not None:
            cleaned_aliases = normalize_alias_list(aliases, canonical_normalized_name=normalized)
        async with get_session() as session:
            async with transaction(session):
                if cleaned_aliases:
                    for a in cleaned_aliases:
                        try:
                            await assert_food_alias_available(
                                session=session,
                                user_key=user_key,
                                alias=a,
                                exclude_normalized_name=normalized,
                            )
                        except ValueError as exc:
                            raise ToolError(str(exc)) from exc
                repo = FoodMemoryRepository(session)
                row = await repo.upsert_usda(
                    user_key=user_key,
                    name=name,
                    normalized_name=normalized,
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
                    aliases=cleaned_aliases,
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

    @mcp.tool
    async def add_food_alias(name: str, alias: str) -> FoodMemoryEntry:
        """Add an alternate phrasing for an existing food memory entry. Looks up the entry
        by canonical `name` (normalized) and appends a normalized `alias` to its aliases.
        Fails when the alias is already used as a canonical name or alias by another entry.
        """
        normalized_name = normalize_name(name)
        normalized_alias = normalize_name(alias)
        if not normalized_alias:
            raise ToolError("Alias must be non-empty after normalization")
        if normalized_alias == normalized_name:
            async with get_session() as session:
                repo = FoodMemoryRepository(session)
                row = await repo.get_by_name(user_key=user_key, normalized_name=normalized_name)
            if row is None:
                raise ToolError("Food memory not found")
            return _food_memory_entry(row)
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            async with transaction(session):
                try:
                    await assert_food_alias_available(
                        session=session,
                        user_key=user_key,
                        alias=normalized_alias,
                        exclude_normalized_name=normalized_name,
                    )
                except ValueError as exc:
                    raise ToolError(str(exc)) from exc
                repo = FoodMemoryRepository(session)
                row = await repo.add_alias(
                    user_key=user_key,
                    normalized_name=normalized_name,
                    alias=normalized_alias,
                    now=now,
                )
            if row is None:
                raise ToolError("Food memory not found")
        return _food_memory_entry(row)

    @mcp.tool
    async def remove_food_alias(name: str, alias: str) -> FoodMemoryEntry:
        """Remove an alternate phrasing from an existing food memory entry. No-op if absent."""
        normalized_name = normalize_name(name)
        normalized_alias = normalize_name(alias)
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = FoodMemoryRepository(session)
            async with transaction(session):
                row = await repo.remove_alias(
                    user_key=user_key,
                    normalized_name=normalized_name,
                    alias=normalized_alias,
                    now=now,
                )
            if row is None:
                raise ToolError("Food memory not found")
        return _food_memory_entry(row)

    # ---------------- meals ----------------

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
                aliases=list(row.get("aliases") or []),
                item_count=int(row["item_count"]),
                total_calories=int(row["total_calories"]),
                total_protein_g=float(row["total_protein_g"]),
                total_carbs_g=float(row["total_carbs_g"]),
                total_fat_g=float(row["total_fat_g"]),
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
            meal_row = await repo.get_meal(meal_uuid, user_key)
            if meal_row is None:
                raise ToolError("Meal not found")
            if normalized_alias == meal_row["normalized_name"]:
                item_rows = await repo.list_items(meal_uuid)
                return _meal_response(meal_row, item_rows)
            async with transaction(session):
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
        return _meal_response(updated, item_rows)

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
        return _meal_response(updated, item_rows)

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
        consumed_dt = _parse_consumed_at(consumed_at, tz)

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


def _parse_consumed_at(value: str | None, tz: ZoneInfo) -> DateTimeValue | None:
    """Parse the MCP ``consumed_at`` argument shared by ``log_food`` / ``log_meal``.

    Accepts either ``YYYY-MM-DD`` (expanded to noon in ``tz``) or any ISO-8601
    timestamp (naive strings are stamped with ``tz``). Returns ``None`` when
    ``value`` is ``None`` so callers can fall back to request-scoped ``now``.

    **Inputs:**
    - value (str | None): Raw user input.
    - tz (ZoneInfo): Server timezone used to localize date-only and naive
      timestamps.

    **Outputs:**
    - datetime | None: Timezone-aware datetime, or ``None`` when no value was
      provided.

    **Exceptions:**
    - ToolError: Raised when ``value`` is non-empty but does not parse as
      either ``YYYY-MM-DD`` or ISO-8601.
    """
    if value is None:
        return None
    try:
        return DateTimeValue.combine(
            DateValue.fromisoformat(value),
            DateTimeValue.min.time().replace(hour=12),
            tzinfo=tz,
        )
    except ValueError:
        pass
    try:
        parsed = DateTimeValue.fromisoformat(value)
    except ValueError as exc:
        raise ToolError(
            f"Invalid consumed_at '{value}', expected YYYY-MM-DD or ISO-8601"
        ) from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=tz)
    return parsed


def _target_and_remaining(
    target_row: dict[str, Any] | None,
    day_totals: MacroTotals,
) -> tuple[MacroTargets | None, MacroTotals | None]:
    """Compute the target profile and remaining-vs-target totals for a day.

    **Inputs:**
    - target_row (dict[str, Any] | None): Row from ``TargetsRepository`` or
      ``None`` when no target profile exists.
    - day_totals (MacroTotals): Consumed macros for the day.

    **Outputs:**
    - tuple[MacroTargets | None, MacroTotals | None]: ``(target, remaining)``
      where both are ``None`` when no profile exists, and ``remaining`` is the
      element-wise difference rounded to one decimal place for macro grams.
    """
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
