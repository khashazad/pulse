"""MCP tools for the per-user food-memory cache.

Registers ``remember_food`` (save a USDA pointer with optional aliases),
``forget_food``, ``list_remembered_foods``, ``add_food_alias``, and
``remove_food_alias``. Responses are built via the shared
:func:`food_memory_entry` adapter so MCP and REST emit one shape (including the
``aliases`` list).
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Literal

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import Field

from pulse_server.db import get_session, transaction
from pulse_server.mcp.context import ToolContext
from pulse_server.models import FoodMemoryEntry, food_memory_entry
from pulse_server.repositories.food_memory import FoodMemoryRepository
from pulse_server.services.alias_utils import normalize_alias_list
from pulse_server.services.food_memory_service import assert_food_alias_available
from pulse_server.services.normalize import normalize_name


def register(mcp: FastMCP, ctx: ToolContext) -> None:
    """Register the food-memory tools on the MCP server.

    **Inputs:**
    - mcp (FastMCP): The server to attach the tool closures to.
    - ctx (ToolContext): Shared context carrying ``user_key`` and ``tz``.

    **Outputs:**
    - None: Tools are registered as a side effect.
    """
    user_key = ctx.user_key
    tz = ctx.tz

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
        return food_memory_entry(row)

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
        return [food_memory_entry(r) for r in rows]

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
            return food_memory_entry(row)
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
        return food_memory_entry(row)

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
        return food_memory_entry(row)
