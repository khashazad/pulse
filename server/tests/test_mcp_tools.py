"""Tests that `build_mcp` registers the documented tool surface and instructions.

Verifies that the MCP server returned by `build_mcp` exposes every tool
the iOS/agent contracts depend on, and that the assembled workflow
instructions reference the canonical helpers (e.g., `resolve_food`,
`list_meals`, alias-management tools).
"""

from __future__ import annotations

from datetime import UTC, date, datetime
from decimal import Decimal
from unittest.mock import MagicMock
from uuid import UUID
from zoneinfo import ZoneInfo

import pytest

from pulse_server.models import FoodEntryResponse
from pulse_server.models.weight import WeightEntryResponse


@pytest.mark.asyncio
async def test_build_mcp_registers_expected_tools() -> None:
    """`build_mcp` registers every tool name the documented agent workflow expects."""
    from pulse_server.mcp import build_mcp

    mcp = build_mcp(lambda: MagicMock())
    tools = await mcp.list_tools()
    names = {t.name for t in tools}
    expected = {
        "search_food",
        "log_food",
        "get_day",
        "get_range",
        "delete_entry",
        "get_targets",
        "set_targets",
        "resolve_food",
        "save_custom_food",
        "update_custom_food",
        "delete_custom_food",
        "list_custom_foods",
        "remember_food",
        "forget_food",
        "list_remembered_foods",
        "add_food_alias",
        "remove_food_alias",
        "create_meal",
        "list_meals",
        "get_meal",
        "update_meal",
        "delete_meal",
        "add_meal_item",
        "update_meal_item",
        "delete_meal_item",
        "log_meal",
        "add_meal_alias",
        "remove_meal_alias",
        "get_weights",
        "get_weight",
    }
    assert expected.issubset(names)


@pytest.mark.asyncio
async def test_build_mcp_emits_workflow_instructions() -> None:
    """The MCP server's instructions string includes the canonical workflow guidance."""
    from pulse_server.mcp import build_mcp
    from pulse_server.mcp.server import WORKFLOW_INSTRUCTIONS

    mcp = build_mcp(lambda: MagicMock())
    assert mcp.instructions is not None
    assert "resolve_food" in mcp.instructions
    assert "list_meals" in mcp.instructions
    assert WORKFLOW_INSTRUCTIONS in mcp.instructions


@pytest.mark.asyncio
async def test_workflow_instructions_mention_aliases() -> None:
    """Workflow instructions reference the alias-management tools."""
    from pulse_server.mcp.server import WORKFLOW_INSTRUCTIONS

    assert "add_meal_alias" in WORKFLOW_INSTRUCTIONS
    assert "add_food_alias" in WORKFLOW_INSTRUCTIONS


def test_basis_for_is_always_per_100g() -> None:
    """FDC nutrients are per-100g for every data type; serving_size is metadata.

    **Inputs:** none (constructs rows inline).

    **Outputs:** none (asserts the basis label).
    """
    from pulse_server.mcp.context import basis_for

    assert basis_for({"serving_size": 112.0}) == "per_100g"
    assert basis_for({"serving_size": None}) == "per_100g"
    assert basis_for({}) == "per_100g"


def _weight_entry(log_date: str, weight_lb: float, source_unit: str = "lb") -> WeightEntryResponse:
    """Build a WeightEntryResponse fixture for summarize_weights tests.

    **Inputs:**
    - log_date (str): ISO date for the entry.
    - weight_lb (float): Stored weight in pounds.
    - source_unit (str): Original entry unit ("lb"/"kg").

    **Outputs:**
    - WeightEntryResponse: A fully-populated entry with fixed id/timestamps.
    """
    ts = datetime(2026, 6, 14, 12, 0, tzinfo=UTC)
    return WeightEntryResponse(
        id=UUID("00000000-0000-0000-0000-000000000001"),
        log_date=date.fromisoformat(log_date),
        weight_lb=Decimal(str(weight_lb)),
        source_unit=source_unit,
        created_at=ts,
        updated_at=ts,
    )


def test_summarize_weights_empty_range() -> None:
    """An empty range yields count 0 and null summary stats."""
    # Arrange
    from datetime import date

    from pulse_server.mcp.tools.weight_tools import summarize_weights

    # Act
    result = summarize_weights(date(2026, 6, 1), date(2026, 6, 30), [])

    # Assert
    assert result.count == 0
    assert result.entries == []
    assert result.latest_lb is None
    assert result.min_lb is None
    assert result.max_lb is None
    assert result.net_change_lb is None


def test_summarize_weights_single_entry_has_null_net_change() -> None:
    """A single entry sets latest/min/max but leaves net_change null."""
    # Arrange
    from datetime import date

    from pulse_server.mcp.tools.weight_tools import summarize_weights

    entries = [_weight_entry("2026-06-10", 180.0)]

    # Act
    result = summarize_weights(date(2026, 6, 1), date(2026, 6, 30), entries)

    # Assert
    assert result.count == 1
    assert result.latest_lb == 180.0
    assert result.min_lb == 180.0
    assert result.max_lb == 180.0
    assert result.net_change_lb is None


def test_summarize_weights_multi_entry_stats() -> None:
    """Multiple ascending entries produce correct min/max/latest and signed net change."""
    # Arrange
    from datetime import date

    from pulse_server.mcp.tools.weight_tools import summarize_weights

    entries = [
        _weight_entry("2026-06-01", 180.0),
        _weight_entry("2026-06-15", 182.0),
        _weight_entry("2026-06-29", 178.5),
    ]

    # Act
    result = summarize_weights(date(2026, 6, 1), date(2026, 6, 30), entries)

    # Assert
    assert result.count == 3
    assert result.latest_lb == 178.5  # last entry (ascending)
    assert result.min_lb == 178.5
    assert result.max_lb == 182.0
    assert result.net_change_lb == -1.5  # last - first = 178.5 - 180.0


# --- get_range: meal grouping, time-of-day bucketing, range assembly --------


def _food_entry(
    *,
    calories: int,
    protein_g: float,
    carbs_g: float,
    fat_g: float,
    consumed_at: datetime,
    meal_id: UUID | None = None,
    meal_name: str | None = None,
    confirmed: bool = True,
) -> FoodEntryResponse:
    """Build a FoodEntryResponse fixture for meal-grouping tests.

    **Inputs:**
    - calories (int): Entry calories.
    - protein_g/carbs_g/fat_g (float): Entry macros.
    - consumed_at (datetime): Timezone-aware consumption timestamp (drives the
      time-of-day fallback bucket and group ordering).
    - meal_id (UUID | None): Saved-meal id, or ``None`` for an ad-hoc entry.
    - meal_name (str | None): Saved-meal name used as the group label when set.
    - confirmed (bool): Whether the entry counts toward totals (default ``True``).

    **Outputs:**
    - FoodEntryResponse: A fully-populated entry with fixed id/group/log ids.
    """
    fixed = UUID("00000000-0000-0000-0000-000000000002")
    return FoodEntryResponse(
        id=fixed,
        daily_log_id=fixed,
        user_key="khash",
        entry_group_id=fixed,
        display_name="x",
        quantity_text="1 serving",
        normalized_quantity_value=None,
        normalized_quantity_unit=None,
        calories=calories,
        protein_g=protein_g,
        carbs_g=carbs_g,
        fat_g=fat_g,
        meal_id=meal_id,
        meal_name=meal_name,
        consumed_at=consumed_at,
        created_at=consumed_at,
        confirmed=confirmed,
    )


def test_time_of_day_bucket_boundaries() -> None:
    """Each hour maps to the documented breakfast/lunch/dinner/snack bucket."""
    from pulse_server.mcp.tools.targets_summary_tools import time_of_day_bucket

    def bucket_at(hour: int) -> str:
        return time_of_day_bucket(datetime(2026, 6, 14, hour, 0, tzinfo=UTC), ZoneInfo("UTC"))

    assert bucket_at(5) == "breakfast"  # lower edge
    assert bucket_at(10) == "breakfast"
    assert bucket_at(11) == "lunch"  # boundary flips to lunch
    assert bucket_at(15) == "lunch"
    assert bucket_at(16) == "dinner"  # boundary flips to dinner
    assert bucket_at(20) == "dinner"
    assert bucket_at(21) == "snack"  # boundary flips to snack
    assert bucket_at(3) == "snack"  # pre-dawn wraps to snack


def test_time_of_day_bucket_projects_utc_timestamp_to_local_tz() -> None:
    """A UTC-stored timestamp is bucketed by its LOCAL hour, not its UTC hour.

    consumed_at is read back from timestamptz as UTC-aware; an 08:00 breakfast in
    America/Toronto (UTC-4 in June) is stored as 12:00Z. Bucketing the raw UTC
    hour (12) would mislabel it as lunch — projecting into the server tz gives
    the correct breakfast.
    """
    from pulse_server.mcp.tools.targets_summary_tools import time_of_day_bucket

    toronto = ZoneInfo("America/Toronto")
    utc_noon = datetime(2026, 6, 14, 12, 0, tzinfo=UTC)  # 08:00 in Toronto

    assert time_of_day_bucket(utc_noon, toronto) == "breakfast"
    assert time_of_day_bucket(utc_noon, ZoneInfo("UTC")) == "lunch"  # raw UTC hour


def test_group_entries_by_meal_buckets_in_local_tz() -> None:
    """Ad-hoc entries bucket by local-tz hour when grouped, not raw UTC hour."""
    from pulse_server.mcp.tools.targets_summary_tools import group_entries_by_meal

    toronto = ZoneInfo("America/Toronto")
    entries = [
        _food_entry(  # 12:00Z == 08:00 Toronto -> breakfast
            calories=300,
            protein_g=20,
            carbs_g=30,
            fat_g=10,
            consumed_at=datetime(2026, 6, 14, 12, 0, tzinfo=UTC),
        ),
    ]

    groups = group_entries_by_meal(entries, toronto)

    assert [g.label for g in groups] == ["breakfast"]


def test_group_entries_by_meal_groups_by_meal_name() -> None:
    """Entries sharing a meal_id collapse into one group labelled by meal_name."""
    from pulse_server.mcp.tools.targets_summary_tools import group_entries_by_meal

    meal = UUID("00000000-0000-0000-0000-0000000000aa")
    ts = datetime(2026, 6, 14, 8, 0, tzinfo=UTC)
    entries = [
        _food_entry(
            calories=200,
            protein_g=10,
            carbs_g=20,
            fat_g=5,
            consumed_at=ts,
            meal_id=meal,
            meal_name="Protein Oatmeal",
        ),
        _food_entry(
            calories=100,
            protein_g=5,
            carbs_g=10,
            fat_g=2,
            consumed_at=ts,
            meal_id=meal,
            meal_name="Protein Oatmeal",
        ),
    ]

    groups = group_entries_by_meal(entries, ZoneInfo("UTC"))

    assert len(groups) == 1
    assert groups[0].label == "Protein Oatmeal"
    assert groups[0].calories == 300
    assert groups[0].protein_g == 15
    assert groups[0].carbs_g == 30
    assert groups[0].fat_g == 7


def test_group_entries_by_meal_null_meal_id_uses_time_of_day() -> None:
    """Entries with meal_id=None bucket by their consumed_at time-of-day."""
    from pulse_server.mcp.tools.targets_summary_tools import group_entries_by_meal

    entries = [
        _food_entry(  # 08:00 -> breakfast
            calories=300,
            protein_g=20,
            carbs_g=30,
            fat_g=10,
            consumed_at=datetime(2026, 6, 14, 8, 0, tzinfo=UTC),
        ),
        _food_entry(  # 13:00 -> lunch
            calories=500,
            protein_g=30,
            carbs_g=50,
            fat_g=15,
            consumed_at=datetime(2026, 6, 14, 13, 0, tzinfo=UTC),
        ),
        _food_entry(  # 22:00 -> snack
            calories=150,
            protein_g=5,
            carbs_g=20,
            fat_g=4,
            consumed_at=datetime(2026, 6, 14, 22, 0, tzinfo=UTC),
        ),
    ]

    groups = group_entries_by_meal(entries, ZoneInfo("UTC"))
    labels = [g.label for g in groups]

    assert labels == ["breakfast", "lunch", "snack"]


def test_group_entries_by_meal_subtotals_sum_to_consumed() -> None:
    """Per-group subtotals add up to the day's consumed totals."""
    from pulse_server.macro_aggregates import sum_food_entry_macros
    from pulse_server.mcp.tools.targets_summary_tools import group_entries_by_meal

    meal = UUID("00000000-0000-0000-0000-0000000000bb")
    entries = [
        _food_entry(
            calories=300,
            protein_g=20,
            carbs_g=30,
            fat_g=10,
            consumed_at=datetime(2026, 6, 14, 8, 0, tzinfo=UTC),
            meal_id=meal,
            meal_name="Breakfast Bowl",
        ),
        _food_entry(
            calories=500,
            protein_g=30,
            carbs_g=50,
            fat_g=15,
            consumed_at=datetime(2026, 6, 14, 13, 0, tzinfo=UTC),
        ),
        _food_entry(
            calories=150,
            protein_g=5,
            carbs_g=20,
            fat_g=4,
            consumed_at=datetime(2026, 6, 14, 22, 0, tzinfo=UTC),
        ),
    ]

    groups = group_entries_by_meal(entries, ZoneInfo("UTC"))
    consumed = sum_food_entry_macros(entries)

    assert sum(g.calories for g in groups) == consumed.calories
    assert round(sum(g.protein_g for g in groups), 1) == consumed.protein_g
    assert round(sum(g.carbs_g for g in groups), 1) == consumed.carbs_g
    assert round(sum(g.fat_g for g in groups), 1) == consumed.fat_g


def test_group_entries_by_meal_orders_by_earliest_consumed_at() -> None:
    """Groups are ordered by the earliest consumed_at within each group."""
    from pulse_server.mcp.tools.targets_summary_tools import group_entries_by_meal

    entries = [
        _food_entry(  # later snack listed first in input
            calories=150,
            protein_g=5,
            carbs_g=20,
            fat_g=4,
            consumed_at=datetime(2026, 6, 14, 22, 0, tzinfo=UTC),
        ),
        _food_entry(  # earlier breakfast
            calories=300,
            protein_g=20,
            carbs_g=30,
            fat_g=10,
            consumed_at=datetime(2026, 6, 14, 7, 0, tzinfo=UTC),
        ),
    ]

    groups = group_entries_by_meal(entries, ZoneInfo("UTC"))

    assert [g.label for g in groups] == ["breakfast", "snack"]


def test_group_entries_by_meal_empty() -> None:
    """No entries yields no groups."""
    from pulse_server.mcp.tools.targets_summary_tools import group_entries_by_meal

    assert group_entries_by_meal([], ZoneInfo("UTC")) == []


def test_build_range_days_excludes_pending_from_by_meal() -> None:
    """``build_range_days`` drops pending entries so ``by_meal`` matches confirmed ``consumed``."""
    from pulse_server.mcp.tools.targets_summary_tools import build_range_days
    from pulse_server.models import DailySummaryResponse, MacroTotals

    summary = DailySummaryResponse(
        date=date(2026, 6, 20),
        target=None,
        # consumed already excludes pending (computed by _assemble_daily_summary).
        consumed=MacroTotals(calories=300, protein_g=20, carbs_g=30, fat_g=10),
        remaining=None,
        entries=[
            _food_entry(
                calories=300,
                protein_g=20,
                carbs_g=30,
                fat_g=10,
                consumed_at=datetime(2026, 6, 20, 8, 0, tzinfo=UTC),
            ),
            _food_entry(
                calories=700,
                protein_g=50,
                carbs_g=40,
                fat_g=20,
                consumed_at=datetime(2026, 6, 20, 13, 0, tzinfo=UTC),
                confirmed=False,
            ),
        ],
    )

    rows = build_range_days([summary], ZoneInfo("UTC"))

    assert len(rows) == 1
    by_meal_calories = sum(group.calories for group in rows[0].by_meal)
    assert by_meal_calories == 300
    assert by_meal_calories == rows[0].consumed.calories


def test_build_range_days_spans_logged_and_unlogged_days() -> None:
    """Every day in the range becomes a row; unlogged days zero-fill."""
    from pulse_server.mcp.tools.targets_summary_tools import build_range_days
    from pulse_server.models import DailySummaryResponse, MacroTargets, MacroTotals

    target = MacroTargets(calories=2000, protein_g=150, carbs_g=200, fat_g=60)
    logged = DailySummaryResponse(
        date=date(2026, 6, 1),
        target=target,
        consumed=MacroTotals(calories=300, protein_g=20, carbs_g=30, fat_g=10),
        remaining=None,
        entries=[
            _food_entry(
                calories=300,
                protein_g=20,
                carbs_g=30,
                fat_g=10,
                consumed_at=datetime(2026, 6, 1, 8, 0, tzinfo=UTC),
            )
        ],
    )
    unlogged = DailySummaryResponse(
        date=date(2026, 6, 2),
        target=target,
        consumed=MacroTotals(calories=0, protein_g=0, carbs_g=0, fat_g=0),
        remaining=None,
        entries=[],
    )

    days = build_range_days([logged, unlogged], ZoneInfo("UTC"))

    assert [d.date for d in days] == [date(2026, 6, 1), date(2026, 6, 2)]
    # Logged day: one breakfast group, consumed carried through, target present.
    assert days[0].target == target
    assert days[0].consumed.calories == 300
    assert [g.label for g in days[0].by_meal] == ["breakfast"]
    # Unlogged day: zero-filled, empty by_meal, target still echoed.
    assert days[1].consumed.calories == 0
    assert days[1].by_meal == []
    assert days[1].target == target
