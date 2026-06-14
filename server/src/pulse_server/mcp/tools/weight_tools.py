"""MCP tools for body-weight retrieval (read-only).

Registers ``get_weights`` (date-range list + summary) and ``get_weight``
(single day). Both reuse the weight service layer that backs the REST
``/weight`` endpoints, so no SQL or business logic is duplicated here. Range
aggregation lives in the pure module-level :func:`summarize_weights` so it is
unit-testable without building the MCP server.

The single-day tool is named ``get_weight``; the service function it calls is
imported as ``fetch_weight_entry`` to avoid the closure shadowing (and
recursing into) itself.
"""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from datetime import timedelta

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError

from pulse_server.db import get_session
from pulse_server.mcp.context import ToolContext, resolve_iso_date
from pulse_server.mcp.models import WeightRange
from pulse_server.models.weight import WeightEntryResponse
from pulse_server.services.weight_service import (
    get_weight as fetch_weight_entry,
)
from pulse_server.services.weight_service import (
    list_weight_range,
)

DEFAULT_RANGE_DAYS = 30


def summarize_weights(
    from_date: DateValue,
    to_date: DateValue,
    entries: list[WeightEntryResponse],
) -> WeightRange:
    """Build a ``WeightRange`` (entries + summary stats) for a resolved range.

    Entries are assumed ascending by ``log_date`` (as the repository returns
    them). Summary stats are in pounds. ``net_change_lb`` is ``last - first``
    and is ``None`` when fewer than two entries are present; all stat fields are
    ``None`` for an empty range.

    **Inputs:**
    - from_date (DateValue): Inclusive lower bound that produced ``entries``.
    - to_date (DateValue): Inclusive upper bound that produced ``entries``.
    - entries (list[WeightEntryResponse]): Weight entries ascending by date.

    **Outputs:**
    - WeightRange: The entries plus computed summary stats.
    """
    weights = [entry.weight_lb for entry in entries]
    return WeightRange(
        from_date=from_date,
        to_date=to_date,
        count=len(entries),
        entries=entries,
        latest_lb=float(weights[-1]) if weights else None,
        min_lb=float(min(weights)) if weights else None,
        max_lb=float(max(weights)) if weights else None,
        net_change_lb=float(weights[-1] - weights[0]) if len(weights) >= 2 else None,
    )


def register(mcp: FastMCP, ctx: ToolContext) -> None:
    """Register the weight-retrieval tools on the MCP server.

    **Inputs:**
    - mcp (FastMCP): The server to attach the tool closures to.
    - ctx (ToolContext): Shared context carrying ``user_key`` and ``tz``.

    **Outputs:**
    - None: Tools are registered as a side effect.
    """
    user_key = ctx.user_key
    tz = ctx.tz

    @mcp.tool
    async def get_weights(
        from_date: str | None = None,
        to_date: str | None = None,
    ) -> WeightRange:
        """Return weight entries for a date range (YYYY-MM-DD), ascending, with summary stats.

        Either bound may be omitted: ``to_date`` defaults to today and a missing
        ``from_date`` defaults to 30 days before the resolved ``to_date`` (both
        bounds inclusive). A bound that is supplied is used as given. Weights and
        summary stats are in pounds; each entry also reports its original
        source_unit. The range may not be reversed or span more than 366 days.
        """
        to_value = resolve_iso_date(to_date, DateTimeValue.now(tz=tz).date())
        from_value = resolve_iso_date(from_date, to_value - timedelta(days=DEFAULT_RANGE_DAYS))
        async with get_session() as session:
            try:
                entries = await list_weight_range(
                    session=session,
                    user_key=user_key,
                    from_date=from_value,
                    to_date=to_value,
                )
            except ValueError as exc:
                raise ToolError(str(exc)) from exc
        return summarize_weights(from_value, to_value, entries)

    @mcp.tool
    async def get_weight(date: str | None = None) -> WeightEntryResponse | None:
        """Return the weight entry for one date (YYYY-MM-DD), or null if none. Defaults to today."""
        day = resolve_iso_date(date, DateTimeValue.now(tz=tz).date())
        async with get_session() as session:
            return await fetch_weight_entry(
                session=session,
                user_key=user_key,
                log_date=day,
            )
