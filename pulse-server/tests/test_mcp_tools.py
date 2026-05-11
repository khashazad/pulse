from __future__ import annotations

from unittest.mock import MagicMock

import pytest


@pytest.mark.asyncio
async def test_build_mcp_registers_expected_tools() -> None:
    from diet_tracker_server.mcp import build_mcp

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
    from diet_tracker_server.mcp import build_mcp
    from diet_tracker_server.mcp.server import WORKFLOW_INSTRUCTIONS

    mcp = build_mcp(lambda: MagicMock())
    assert mcp.instructions is not None
    assert "resolve_food" in mcp.instructions
    assert "list_meals" in mcp.instructions
    assert WORKFLOW_INSTRUCTIONS in mcp.instructions


@pytest.mark.asyncio
async def test_workflow_instructions_mention_aliases() -> None:
    from diet_tracker_server.mcp.server import WORKFLOW_INSTRUCTIONS
    assert "add_meal_alias" in WORKFLOW_INSTRUCTIONS
    assert "add_food_alias" in WORKFLOW_INSTRUCTIONS
