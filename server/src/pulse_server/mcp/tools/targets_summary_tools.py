"""MCP tools for macro targets and per-day summaries.

Registers ``get_day`` (entries + totals for a date), ``get_targets``, and
``set_targets``. ``get_day`` calls ``build_daily_summary`` with
``missing_target="null"`` so a day with no target profile still returns the
consumed totals and entries (``target``/``remaining`` are ``None``) instead of
the 404 the REST ``/summary`` endpoint raises.
"""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import Field

from pulse_server.db import get_session, transaction
from pulse_server.mcp.context import ToolContext
from pulse_server.mcp.models import DaySummary
from pulse_server.models import MacroTargets
from pulse_server.models.adapters import macro_targets_from_row
from pulse_server.repositories.targets import TargetsRepository
from pulse_server.services.summary_service import build_daily_summary


def register(mcp: FastMCP, ctx: ToolContext) -> None:
    """Register the day-summary and macro-target tools on the MCP server.

    **Inputs:**
    - mcp (FastMCP): The server to attach the tool closures to.
    - ctx (ToolContext): Shared context carrying ``user_key`` and ``tz``.

    **Outputs:**
    - None: Tools are registered as a side effect.
    """
    user_key = ctx.user_key
    tz = ctx.tz

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
            summary = await build_daily_summary(
                session=session,
                user_key=user_key,
                summary_date=day,
                missing_target="null",
            )
        return DaySummary(
            date=summary.date,
            target=summary.target,
            consumed=summary.consumed,
            remaining=summary.remaining,
            entries=summary.entries,
        )

    @mcp.tool
    async def get_targets() -> MacroTargets | None:
        """Return the configured macro targets, or null if none are set."""
        async with get_session() as session:
            repo = TargetsRepository(session)
            row = await repo.get_target_profile(user_key)
        if row is None:
            return None
        return macro_targets_from_row(row)

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
