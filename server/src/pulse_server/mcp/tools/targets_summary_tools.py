"""MCP tools for macro targets and per-day / multi-day summaries.

Registers ``get_day`` (full entries + totals for one date), ``get_range``
(lightweight per-day macro rollups across a date range, grouped by meal — no
individual entries), ``get_targets``, and ``set_targets``. ``get_day`` calls
``build_daily_summary`` with ``missing_target="null"`` so a day with no target
profile still returns the consumed totals and entries (``target``/``remaining``
are ``None``) instead of the 404 the REST ``/summary`` endpoint raises;
``get_range`` loops the same per-day logic and aggregates each day's entries
into meal-group subtotals.

The meal-grouping and range-assembly helpers (:func:`time_of_day_bucket`,
:func:`group_entries_by_meal`, :func:`build_range_days`) are pure and
module-level so they are unit-testable without building the MCP server.
"""

from __future__ import annotations

from collections.abc import Sequence
from datetime import datetime as DateTimeValue
from zoneinfo import ZoneInfo

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import Field

from pulse_server.db import get_session, transaction
from pulse_server.macro_aggregates import sum_food_entry_macros
from pulse_server.mcp.context import ToolContext, parse_iso_date
from pulse_server.mcp.models import DaySummary, MealGroup, RangeDay, RangeSummary
from pulse_server.models import DailySummaryResponse, FoodEntryResponse, MacroTargets
from pulse_server.models.adapters import macro_targets_from_row
from pulse_server.repositories.targets import TargetsRepository
from pulse_server.services.summary_service import build_daily_summary, build_range_summaries

# Time-of-day bucket boundaries (server-tz hour, 24h). An entry's hour falls in
# breakfast [5,11), lunch [11,16), dinner [16,21); everything else is a snack
# (late night / pre-dawn). Used only for ad-hoc entries that have no meal_id.
BREAKFAST_START_HOUR = 5
LUNCH_START_HOUR = 11
DINNER_START_HOUR = 16
SNACK_START_HOUR = 21


def time_of_day_bucket(consumed_at: DateTimeValue, tz: ZoneInfo) -> str:
    """Map a consumption timestamp to a breakfast/lunch/dinner/snack bucket.

    ``consumed_at`` is read back from a ``timestamptz`` column as a UTC-aware
    datetime (the DB session is not pinned to the server timezone), so it is
    projected into ``tz`` before its hour is bucketed — the same projection the
    write path applies when deriving an entry's calendar day. A naive
    ``consumed_at`` (no ``tzinfo``) is bucketed on its own hour unchanged.

    **Inputs:**
    - consumed_at (datetime): The entry's consumption timestamp.
    - tz (ZoneInfo): Server timezone to project the timestamp into.

    **Outputs:**
    - str: One of ``"breakfast"`` ([05:00, 11:00)), ``"lunch"`` ([11:00,
      16:00)), ``"dinner"`` ([16:00, 21:00)), or ``"snack"`` (all other hours),
      in local ``tz`` time.
    """
    local = consumed_at.astimezone(tz) if consumed_at.tzinfo is not None else consumed_at
    hour = local.hour
    if BREAKFAST_START_HOUR <= hour < LUNCH_START_HOUR:
        return "breakfast"
    if LUNCH_START_HOUR <= hour < DINNER_START_HOUR:
        return "lunch"
    if DINNER_START_HOUR <= hour < SNACK_START_HOUR:
        return "dinner"
    return "snack"


def group_entries_by_meal(entries: Sequence[FoodEntryResponse], tz: ZoneInfo) -> list[MealGroup]:
    """Roll a day's food entries up into per-meal macro subtotals.

    Entries logged from a saved meal (``meal_name`` set) group under that name;
    ad-hoc entries (no ``meal_name``) group by the :func:`time_of_day_bucket` of
    their ``consumed_at`` in local ``tz`` time. Groups are ordered by the
    earliest ``consumed_at`` within each group, and the subtotals sum to the
    day's consumed totals.

    **Inputs:**
    - entries (Sequence[FoodEntryResponse]): The day's food entries in any order.
    - tz (ZoneInfo): Server timezone used to bucket ad-hoc entries by hour.

    **Outputs:**
    - list[MealGroup]: One labelled macro subtotal per meal group, chronological
      by each group's earliest entry. Empty when ``entries`` is empty.
    """
    groups: dict[str, list[FoodEntryResponse]] = {}
    for entry in entries:
        label = entry.meal_name if entry.meal_name else time_of_day_bucket(entry.consumed_at, tz)
        groups.setdefault(label, []).append(entry)

    ordered = sorted(
        groups.items(),
        key=lambda item: min(entry.consumed_at for entry in item[1]),
    )
    return [
        MealGroup(label=label, **sum_food_entry_macros(group_entries).model_dump())
        for label, group_entries in ordered
    ]


def build_range_days(summaries: Sequence[DailySummaryResponse], tz: ZoneInfo) -> list[RangeDay]:
    """Map per-day summaries into lightweight meal-grouped range rows.

    Each summary's entries are collapsed into meal-group subtotals; the entries
    themselves are dropped. Unlogged days (empty ``entries``) pass through as
    zero-filled rows with an empty ``by_meal`` list.

    **Inputs:**
    - summaries (Sequence[DailySummaryResponse]): One summary per calendar day,
      in date order, as produced by :func:`build_daily_summary`.
    - tz (ZoneInfo): Server timezone used to bucket ad-hoc entries by hour.

    **Outputs:**
    - list[RangeDay]: One row per input summary, preserving order.
    """
    return [
        RangeDay(
            date=summary.date,
            target=summary.target,
            consumed=summary.consumed,
            by_meal=group_entries_by_meal(summary.entries, tz),
        )
        for summary in summaries
    ]


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
        """Return every food entry + totals for ONE `date` (YYYY-MM-DD). Defaults to today.

        Use this only when you need the individual food entries for a single day
        (e.g. to find an entry's id before editing/deleting it). For weekly or
        multi-day macro summaries, call `get_range` instead — it returns per-meal
        subtotals per day without the full (often 30+) entry list, so it is far
        cheaper than calling `get_day` once per day.
        """
        day = DateTimeValue.now(tz=tz).date() if date is None else parse_iso_date(date)
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
    async def get_range(start: str, end: str) -> RangeSummary:
        """Return lightweight per-day macro rollups for an inclusive date range.

        Prefer this over `get_day` for any weekly/multi-day summary: it returns
        one row per day with the day's target, consumed totals, and per-meal
        subtotals (`by_meal`) — but NOT the individual food entries — so a week
        is one cheap call instead of seven heavy `get_day` calls. Use `get_day`
        only when you need a single day's individual entries.

        `start` and `end` are `YYYY-MM-DD`, both inclusive; the range may not be
        reversed or span more than 366 days. Every day in the range appears in
        `days`, including unlogged days (zero-filled: `consumed` all zeros,
        `by_meal` empty). Within each day, `by_meal` groups entries by saved-meal
        name when present, otherwise by time-of-day bucket
        (breakfast/lunch/dinner/snack) of `consumed_at`, ordered chronologically;
        the subtotals sum to that day's `consumed`.
        """
        start_value = parse_iso_date(start)
        end_value = parse_iso_date(end)
        async with get_session() as session:
            try:
                summaries = await build_range_summaries(
                    session=session,
                    user_key=user_key,
                    from_date=start_value,
                    to_date=end_value,
                )
            except ValueError as exc:
                raise ToolError(str(exc)) from exc
        return RangeSummary(
            from_date=start_value,
            to_date=end_value,
            days=build_range_days(summaries, tz),
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
