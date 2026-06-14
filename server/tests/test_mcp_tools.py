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

import pytest

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
    assert result.latest_lb == 178.5            # last entry (ascending)
    assert result.min_lb == 178.5
    assert result.max_lb == 182.0
    assert result.net_change_lb == -1.5         # last - first = 178.5 - 180.0
