"""MCP tools for user-defined custom foods.

Registers ``save_custom_food`` (create-or-update with an atomic memory write),
``update_custom_food`` (partial field update), ``delete_custom_food``, and
``list_custom_foods``. Responses are built via the shared
:func:`custom_food_response` adapter so MCP and REST emit one shape.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Literal
from uuid import UUID

from fastapi import HTTPException
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import Field
from sqlalchemy.exc import IntegrityError

from pulse_server.db import get_session, transaction
from pulse_server.mcp.context import ToolContext
from pulse_server.models import (
    CustomFoodCreate,
    CustomFoodResponse,
    CustomFoodUpdate,
    FoodListResponse,
    custom_food_response,
    food_response,
)
from pulse_server.repositories.custom_foods import CustomFoodsRepository
from pulse_server.repositories.foods import FoodsRepository
from pulse_server.services.custom_foods_service import upsert_custom_food_and_remember
from pulse_server.services.foods_service import attach_portion, list_foods_with_portions
from pulse_server.services.normalize import normalize_name


def register(mcp: FastMCP, ctx: ToolContext) -> None:
    """Register the custom-food CRUD tools on the MCP server.

    **Inputs:**
    - mcp (FastMCP): The server to attach the tool closures to.
    - ctx (ToolContext): Shared context carrying ``user_key`` and ``tz``.

    **Outputs:**
    - None: Tools are registered as a side effect.
    """
    user_key = ctx.user_key
    tz = ctx.tz

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
        food_id: str | None = None,
        food_name: str | None = None,
        portion_label: str | None = None,
    ) -> CustomFoodResponse:
        """Create or update a user-defined food (no USDA equivalent). Also writes food_memory
        so future mentions of `name` resolve to this custom food automatically.

        For photo-derived foods, default `basis="per_serving"` and provide `serving_size`/
        `serving_size_unit` (e.g. 1 / "wrap"). The macros are per the indicated basis.

        To file this food as a portion of an existing grouped food, pass `food_id`
        (preferred) or `food_name` plus an optional `portion_label` (e.g. "large").
        The food is created, then attached as a portion; its name folds into the
        Food's aliases so future mentions resolve to the Food.
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
        async with get_session() as session, transaction(session):
            row = await upsert_custom_food_and_remember(
                session=session, user_key=user_key, payload=payload, now=now
            )
            target_food_id: UUID | None = None
            if food_id is not None:
                try:
                    target_food_id = UUID(food_id)
                except ValueError as exc:
                    raise ToolError(f"Invalid food_id '{food_id}'") from exc
            elif food_name is not None:
                foods_repo = FoodsRepository(session)
                food = await foods_repo.get_by_name(user_key, normalize_name(food_name))
                if food is None:
                    raise ToolError(f"No food named '{food_name}' to attach to")
                target_food_id = food["id"]
            if target_food_id is not None:
                try:
                    await attach_portion(
                        session, user_key, target_food_id, row["id"], portion_label, now
                    )
                except HTTPException as exc:
                    raise ToolError(str(exc.detail)) from exc
                refreshed = await CustomFoodsRepository(session).get_by_id(row["id"], user_key)
                if refreshed is not None:
                    row = refreshed
        return custom_food_response(row)

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

        # In this tool `None` means "leave unchanged" for every field, so only
        # forward the explicitly-provided ones. Constructing CustomFoodUpdate
        # from the full kwargs would mark all fields as set and write nulls into
        # the omitted (NOT NULL) columns.
        provided = {
            "name": name,
            "basis": basis,
            "serving_size": serving_size,
            "serving_size_unit": serving_size_unit,
            "calories": calories,
            "protein_g": protein_g,
            "carbs_g": carbs_g,
            "fat_g": fat_g,
            "source": source,
            "notes": notes,
        }
        payload = CustomFoodUpdate.model_validate(
            {k: v for k, v in provided.items() if v is not None}
        )
        fields = payload.model_dump(exclude_unset=True)
        if "name" in fields and fields["name"] is not None:
            fields["normalized_name"] = normalize_name(fields["name"])

        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = CustomFoodsRepository(session)
            try:
                async with transaction(session):
                    row = await repo.update_fields(cf_uuid, user_key, fields, now)
            except IntegrityError as exc:
                raise ToolError("A custom food with that name already exists") from exc
        if row is None:
            raise ToolError("Custom food not found")
        return custom_food_response(row)

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
    async def list_custom_foods() -> FoodListResponse:
        """List this user's foods. Grouped foods appear under `foods` (each with its
        nested `portions`); ungrouped custom foods appear under `standalones`. Resolve
        a name with `resolve_food` before logging — a grouped food's portions carry the
        `custom_food_id` you log with.
        """
        async with get_session() as session:
            foods, standalones = await list_foods_with_portions(session, user_key)
        return FoodListResponse(
            foods=[food_response(f, p, a) for (f, p, a) in foods],
            standalones=[custom_food_response(r) for r in standalones],
        )
