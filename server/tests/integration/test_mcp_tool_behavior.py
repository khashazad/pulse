"""Integration tests exercising the MCP tools end-to-end via the in-memory client.

Builds the FastMCP server with :func:`build_mcp` (using a stub USDA client) and
drives the tools through the FastMCP in-memory ``Client`` against a real
Postgres (``TEST_DATABASE_URL``). These tests lock in the refactor's two allowed
wire changes — ``log_food``/``log_meal`` return ``daily_totals`` (not the old
``day_totals``) and meal/food-memory responses carry ``aliases`` — and confirm
``get_day`` behaves identically for both the target-set and no-target cases.

The tools run against the module-level ``db`` pool, so the fixture initializes
that pool, bootstraps the schema, and truncates the relevant tables between
tests (mirroring ``tests/integration/test_weight_integration.py``).
"""

from __future__ import annotations

import os
from typing import Any

import pytest
import pytest_asyncio
from fastmcp import Client
from sqlalchemy import text

from pulse_server import db
from pulse_server.mcp import build_mcp

pytestmark = pytest.mark.integration


class _StubUSDAClient:
    """Minimal stand-in for ``USDAClient`` so ``search_food`` runs without HTTP.

    **Inputs:**
    - None.

    **Outputs:**
    - _StubUSDAClient: An instance whose :meth:`search` returns one canned hit.
    """

    async def search(self, query: str, page_size: int = 5) -> list[dict[str, Any]]:
        """Return a single canned normalized USDA food row for any query.

        **Inputs:**
        - query (str): The search text (echoed indirectly via the candidate).
        - page_size (int): Ignored; the stub always returns one row.

        **Outputs:**
        - list[dict[str, Any]]: One normalized food row with per-100g macros.
        """
        return [
            {
                "fdc_id": 123456,
                "description": f"Stub result for {query}",
                "serving_size": None,
                "serving_size_unit": None,
                "calories": 200,
                "protein_g": 10.0,
                "carbs_g": 20.0,
                "fat_g": 5.0,
            }
        ]


@pytest_asyncio.fixture
async def mcp_server():
    """Initialize the DB pool, bootstrap schema, truncate tables, and yield a built MCP server.

    **Outputs:**
    - FastMCP: Server wired with the stub USDA client, ready for the in-memory
      client. Skips when ``TEST_DATABASE_URL`` is unset.
    """
    test_db_url = os.environ.get("TEST_DATABASE_URL")
    if test_db_url is None:
        pytest.skip("Set TEST_DATABASE_URL to run integration tests")
    await db.init_pool(test_db_url)
    await db.bootstrap_schema()
    async with db.get_session() as session:
        await session.execute(
            text(
                "truncate table food_entries, meal_items, meals, food_memory, "
                "custom_foods, daily_logs, daily_target_profile, containers "
                "restart identity cascade"
            )
        )
        await session.commit()
    try:
        yield build_mcp(lambda: _StubUSDAClient())
    finally:
        await db.close_pool()


@pytest.mark.asyncio
async def test_log_food_returns_daily_totals_not_day_totals(mcp_server) -> None:
    """``log_food`` returns a ``daily_totals`` field (allowed wire change #2)."""
    async with Client(mcp_server) as client:
        result = await client.call_tool(
            "log_food",
            {
                "display_name": "Stub Oats",
                "quantity_text": "1 bowl",
                "calories": 300,
                "protein_g": 12.0,
                "carbs_g": 50.0,
                "fat_g": 6.0,
                "fdc_id": 999,
                "usda_description": "Oats, raw",
            },
        )
    payload = result.structured_content
    assert "daily_totals" in payload
    assert "day_totals" not in payload
    assert payload["daily_totals"]["calories"] == 300
    assert payload["entry"]["display_name"] == "Stub Oats"


@pytest.mark.asyncio
async def test_search_food_uses_stub_and_reports_basis(mcp_server) -> None:
    """``search_food`` returns the stub candidate with a per_100g basis."""
    async with Client(mcp_server) as client:
        result = await client.call_tool("search_food", {"description": "oatmeal"})
    payload = result.structured_content
    assert payload["query"] == "oatmeal"
    assert len(payload["candidates"]) == 1
    candidate = payload["candidates"][0]
    assert candidate["fdc_id"] == 123456
    assert candidate["basis"] == "per_100g"


@pytest.mark.asyncio
async def test_log_meal_returns_daily_totals(mcp_server) -> None:
    """``log_meal`` returns ``daily_totals`` and one entry per meal item."""
    async with Client(mcp_server) as client:
        created = await client.call_tool(
            "create_meal",
            {
                "name": "Test Breakfast",
                "items": [
                    {
                        "display_name": "Eggs",
                        "quantity_text": "2 large",
                        "usda_fdc_id": 111,
                        "usda_description": "Egg, whole",
                        "calories": 140,
                        "protein_g": 12.0,
                        "carbs_g": 1.0,
                        "fat_g": 10.0,
                    },
                    {
                        "display_name": "Toast",
                        "quantity_text": "1 slice",
                        "usda_fdc_id": 222,
                        "usda_description": "Bread, white",
                        "calories": 80,
                        "protein_g": 3.0,
                        "carbs_g": 15.0,
                        "fat_g": 1.0,
                    },
                ],
            },
        )
        meal_id = created.structured_content["id"]

        logged = await client.call_tool("log_meal", {"meal_id": meal_id})

    payload = logged.structured_content
    assert "daily_totals" in payload
    assert "day_totals" not in payload
    assert len(payload["entries"]) == 2
    assert payload["daily_totals"]["calories"] == 220


@pytest.mark.asyncio
async def test_get_day_with_target_set(mcp_server) -> None:
    """``get_day`` returns the target profile and remaining macros when a target is set."""
    async with Client(mcp_server) as client:
        await client.call_tool(
            "set_targets",
            {"calories": 2000, "protein_g": 150.0, "carbs_g": 200.0, "fat_g": 60.0},
        )
        await client.call_tool(
            "log_food",
            {
                "display_name": "Chicken",
                "quantity_text": "200 g",
                "calories": 330,
                "protein_g": 62.0,
                "carbs_g": 0.0,
                "fat_g": 7.0,
                "fdc_id": 555,
                "usda_description": "Chicken breast, cooked",
            },
        )
        result = await client.call_tool("get_day", {})

    payload = result.structured_content
    assert payload["target"] is not None
    assert payload["target"]["calories"] == 2000
    assert payload["remaining"] is not None
    assert payload["remaining"]["calories"] == 2000 - 330
    assert payload["consumed"]["calories"] == 330
    assert len(payload["entries"]) == 1


@pytest.mark.asyncio
async def test_get_day_with_no_target(mcp_server) -> None:
    """``get_day`` falls back to null target/remaining when no profile exists (unchanged behavior)."""
    async with Client(mcp_server) as client:
        await client.call_tool(
            "log_food",
            {
                "display_name": "Apple",
                "quantity_text": "1 medium",
                "calories": 95,
                "protein_g": 0.5,
                "carbs_g": 25.0,
                "fat_g": 0.3,
                "fdc_id": 777,
                "usda_description": "Apple, raw",
            },
        )
        result = await client.call_tool("get_day", {})

    payload = result.structured_content
    assert payload["target"] is None
    assert payload["remaining"] is None
    assert payload["consumed"]["calories"] == 95
    assert len(payload["entries"]) == 1


@pytest.mark.asyncio
async def test_resolve_food_miss_then_hit_after_remember(mcp_server) -> None:
    """``resolve_food`` returns ``type=none`` before a memory exists and the USDA hit after."""
    async with Client(mcp_server) as client:
        miss = await client.call_tool("resolve_food", {"name": "peanut butter"})
        assert miss.structured_content["type"] == "none"

        await client.call_tool(
            "remember_food",
            {
                "name": "peanut butter",
                "fdc_id": 321,
                "usda_description": "Peanut butter, smooth",
                "basis": "per_100g",
                "calories": 588,
                "protein_g": 25.0,
                "carbs_g": 20.0,
                "fat_g": 50.0,
            },
        )
        hit = await client.call_tool("resolve_food", {"name": "peanut butter"})

    assert hit.structured_content["type"] == "memory_usda"
    assert hit.structured_content["usda_fdc_id"] == 321


@pytest.mark.asyncio
async def test_create_meal_and_get_meal_include_aliases(mcp_server) -> None:
    """``create_meal`` and ``get_meal`` responses include the ``aliases`` list (allowed wire change #1)."""
    async with Client(mcp_server) as client:
        created = await client.call_tool(
            "create_meal",
            {
                "name": "Wrap Lunch",
                "aliases": ["the wrap"],
                "items": [
                    {
                        "display_name": "Wrap",
                        "quantity_text": "1 wrap",
                        "usda_fdc_id": 444,
                        "usda_description": "Tortilla wrap",
                        "calories": 250,
                        "protein_g": 8.0,
                        "carbs_g": 40.0,
                        "fat_g": 6.0,
                    }
                ],
            },
        )
        assert "aliases" in created.structured_content
        assert created.structured_content["aliases"] == ["the wrap"]
        meal_id = created.structured_content["id"]

        fetched = await client.call_tool("get_meal", {"meal_id": meal_id})

    assert "aliases" in fetched.structured_content
    assert fetched.structured_content["aliases"] == ["the wrap"]


@pytest.mark.asyncio
async def test_add_food_alias_appends_to_memory(mcp_server) -> None:
    """``add_food_alias`` appends a normalized alias and returns it on the entry."""
    async with Client(mcp_server) as client:
        await client.call_tool(
            "remember_food",
            {
                "name": "greek yogurt",
                "fdc_id": 888,
                "usda_description": "Yogurt, Greek, plain",
                "basis": "per_100g",
                "calories": 59,
                "protein_g": 10.0,
                "carbs_g": 3.6,
                "fat_g": 0.4,
            },
        )
        result = await client.call_tool(
            "add_food_alias", {"name": "greek yogurt", "alias": "the yogurt"}
        )

    assert "the yogurt" in result.structured_content["aliases"]


@pytest.mark.asyncio
async def test_add_meal_alias_no_op_when_alias_equals_name(mcp_server) -> None:
    """``add_meal_alias`` with the canonical name as the alias returns the meal unchanged.

    This exercises the early-return branch (``normalized_alias == normalized_name``)
    that the refactor preserved verbatim, and confirms the meal payload still carries
    the ``aliases`` list (allowed wire change #1).
    """
    async with Client(mcp_server) as client:
        created = await client.call_tool(
            "create_meal",
            {
                "name": "Dinner Plate",
                "items": [
                    {
                        "display_name": "Rice",
                        "quantity_text": "1 cup",
                        "usda_fdc_id": 666,
                        "usda_description": "Rice, cooked",
                        "calories": 200,
                        "protein_g": 4.0,
                        "carbs_g": 45.0,
                        "fat_g": 0.5,
                    }
                ],
            },
        )
        meal_id = created.structured_content["id"]
        result = await client.call_tool(
            "add_meal_alias", {"meal_id": meal_id, "alias": "Dinner Plate"}
        )

    # No alias added (the phrasing is the canonical name); response still carries aliases.
    assert "aliases" in result.structured_content
    assert result.structured_content["aliases"] == []


@pytest.mark.asyncio
async def test_add_meal_alias_appends_new_alias(mcp_server) -> None:
    """``add_meal_alias`` appends a new alias and returns it in the meal's ``aliases``.

    Previously the ``get_meal`` lookup ran directly on the session (triggering
    SQLAlchemy autobegin) before ``transaction(session)`` called ``session.begin()``,
    raising "A transaction is already begun on this Session." Moving the lookup inside
    the transaction (mirroring ``add_food_alias`` / ``add_meal_item``) fixes the append
    path, so a distinct alias now persists and surfaces in the response.
    """
    async with Client(mcp_server) as client:
        created = await client.call_tool(
            "create_meal",
            {
                "name": "Lunch Plate",
                "items": [
                    {
                        "display_name": "Rice",
                        "quantity_text": "1 cup",
                        "usda_fdc_id": 667,
                        "usda_description": "Rice, cooked",
                        "calories": 200,
                        "protein_g": 4.0,
                        "carbs_g": 45.0,
                        "fat_g": 0.5,
                    }
                ],
            },
        )
        meal_id = created.structured_content["id"]
        result = await client.call_tool(
            "add_meal_alias", {"meal_id": meal_id, "alias": "the plate"}
        )

    assert "the plate" in result.structured_content["aliases"]


# --------------------------------------------------------------------------- #
# Shared helpers used by the extended coverage tests below.
# --------------------------------------------------------------------------- #


def _raised_tool_error(exc_info: pytest.ExceptionInfo) -> bool:
    """Return whether a captured FastMCP client exception is a tool error.

    **Inputs:**
    - exc_info (pytest.ExceptionInfo): Captured exception from ``pytest.raises``.

    **Outputs:**
    - bool: ``True`` when the exception is a FastMCP ``ToolError`` (server-side
      validation/error branch surfaced to the in-memory client).
    """
    from fastmcp.exceptions import ToolError

    return isinstance(exc_info.value, ToolError)


_SIMPLE_MEAL_ITEM = {
    "display_name": "Rice",
    "quantity_text": "1 cup",
    "usda_fdc_id": 700,
    "usda_description": "Rice, cooked",
    "calories": 200,
    "protein_g": 4.0,
    "carbs_g": 45.0,
    "fat_g": 0.5,
}


# --------------------------------------------------------------------------- #
# Custom-food tools.
# --------------------------------------------------------------------------- #


@pytest.mark.asyncio
async def test_save_and_list_custom_food(mcp_server) -> None:
    """``save_custom_food`` persists a row that ``list_custom_foods`` returns."""
    async with Client(mcp_server) as client:
        saved = await client.call_tool(
            "save_custom_food",
            {
                "name": "Protein Bar",
                "basis": "per_serving",
                "calories": 210,
                "protein_g": 20.0,
                "carbs_g": 22.0,
                "fat_g": 7.0,
                "serving_size": 1,
                "serving_size_unit": "bar",
                "source": "manual",
            },
        )
        assert saved.structured_content["name"] == "Protein Bar"

        listed = await client.call_tool("list_custom_foods", {})
    rows = listed.structured_content["result"]
    assert any(r["name"] == "Protein Bar" for r in rows)


@pytest.mark.asyncio
async def test_save_custom_food_also_writes_memory(mcp_server) -> None:
    """``save_custom_food`` writes food memory so ``resolve_food`` returns a custom_food hit."""
    async with Client(mcp_server) as client:
        await client.call_tool(
            "save_custom_food",
            {
                "name": "Homemade Granola",
                "basis": "per_100g",
                "calories": 450,
                "protein_g": 10.0,
                "carbs_g": 60.0,
                "fat_g": 18.0,
            },
        )
        resolved = await client.call_tool("resolve_food", {"name": "homemade granola"})
    assert resolved.structured_content["type"] == "custom_food"


@pytest.mark.asyncio
async def test_update_custom_food_changes_fields(mcp_server) -> None:
    """``update_custom_food`` applies a partial update and returns the new values."""
    async with Client(mcp_server) as client:
        saved = await client.call_tool(
            "save_custom_food",
            {
                "name": "Smoothie",
                "basis": "per_serving",
                "calories": 300,
                "protein_g": 25.0,
                "carbs_g": 40.0,
                "fat_g": 5.0,
            },
        )
        cf_id = saved.structured_content["id"]
        updated = await client.call_tool(
            "update_custom_food", {"custom_food_id": cf_id, "calories": 320, "name": "Big Smoothie"}
        )
    payload = updated.structured_content
    assert payload["calories"] == 320
    assert payload["name"] == "Big Smoothie"


@pytest.mark.asyncio
async def test_update_custom_food_invalid_id_raises_tool_error(mcp_server) -> None:
    """``update_custom_food`` with a non-UUID id raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "update_custom_food", {"custom_food_id": "not-a-uuid", "calories": 1}
            )
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_update_custom_food_missing_raises_tool_error(mcp_server) -> None:
    """``update_custom_food`` on an unknown (well-formed) id raises 'Custom food not found'."""
    import uuid

    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "update_custom_food", {"custom_food_id": str(uuid.uuid4()), "calories": 1}
            )
    assert _raised_tool_error(exc_info)
    assert "not found" in str(exc_info.value).lower()


@pytest.mark.asyncio
async def test_delete_custom_food_succeeds(mcp_server) -> None:
    """``delete_custom_food`` removes an unreferenced custom food and reports deleted=True."""
    async with Client(mcp_server) as client:
        saved = await client.call_tool(
            "save_custom_food",
            {
                "name": "Throwaway",
                "basis": "per_serving",
                "calories": 100,
                "protein_g": 1.0,
                "carbs_g": 1.0,
                "fat_g": 1.0,
            },
        )
        cf_id = saved.structured_content["id"]
        deleted = await client.call_tool("delete_custom_food", {"custom_food_id": cf_id})
    assert deleted.structured_content["deleted"] is True


@pytest.mark.asyncio
async def test_delete_custom_food_invalid_id_raises_tool_error(mcp_server) -> None:
    """``delete_custom_food`` with a malformed id raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("delete_custom_food", {"custom_food_id": "xyz"})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_delete_custom_food_referenced_raises_tool_error(mcp_server) -> None:
    """``delete_custom_food`` refuses to delete a custom food still referenced by a logged entry."""
    async with Client(mcp_server) as client:
        saved = await client.call_tool(
            "save_custom_food",
            {
                "name": "Referenced Food",
                "basis": "per_serving",
                "calories": 100,
                "protein_g": 5.0,
                "carbs_g": 10.0,
                "fat_g": 2.0,
            },
        )
        cf_id = saved.structured_content["id"]
        await client.call_tool(
            "log_food",
            {
                "display_name": "Referenced Food",
                "quantity_text": "1 serving",
                "calories": 100,
                "protein_g": 5.0,
                "carbs_g": 10.0,
                "fat_g": 2.0,
                "custom_food_id": cf_id,
            },
        )
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("delete_custom_food", {"custom_food_id": cf_id})
    assert _raised_tool_error(exc_info)
    assert "referenced" in str(exc_info.value).lower()


# --------------------------------------------------------------------------- #
# Container tools.
# --------------------------------------------------------------------------- #


@pytest.mark.asyncio
async def test_save_list_update_delete_container(mcp_server) -> None:
    """The container CRUD tools round-trip: save, list, update, delete."""
    async with Client(mcp_server) as client:
        saved = await client.call_tool(
            "save_container", {"name": "Big Pyrex", "tare_weight_g": 412.0}
        )
        cid = saved.structured_content["id"]
        assert saved.structured_content["tare_weight_g"] == 412.0

        listed = await client.call_tool("list_containers", {})
        assert any(r["id"] == cid for r in listed.structured_content["result"])

        updated = await client.call_tool(
            "update_container",
            {"container_id": cid, "name": "Renamed Pyrex", "tare_weight_g": 400.0},
        )
        assert updated.structured_content["name"] == "Renamed Pyrex"
        assert updated.structured_content["tare_weight_g"] == 400.0

        deleted = await client.call_tool("delete_container", {"container_id": cid})
    assert deleted.structured_content["deleted"] is True


@pytest.mark.asyncio
async def test_save_container_duplicate_name_raises_tool_error(mcp_server) -> None:
    """``save_container`` rejects a second container with a duplicate name."""
    async with Client(mcp_server) as client:
        await client.call_tool("save_container", {"name": "Dup Box", "tare_weight_g": 10.0})
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("save_container", {"name": "Dup Box", "tare_weight_g": 11.0})
    assert _raised_tool_error(exc_info)
    assert "already exists" in str(exc_info.value).lower()


@pytest.mark.asyncio
async def test_update_container_invalid_id_raises_tool_error(mcp_server) -> None:
    """``update_container`` with a non-UUID id raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("update_container", {"container_id": "nope", "name": "X"})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_update_container_missing_raises_tool_error(mcp_server) -> None:
    """``update_container`` on an unknown id raises 'Container not found'."""
    import uuid

    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "update_container", {"container_id": str(uuid.uuid4()), "name": "Ghost"}
            )
    assert _raised_tool_error(exc_info)
    assert "not found" in str(exc_info.value).lower()


@pytest.mark.asyncio
async def test_delete_container_invalid_id_raises_tool_error(mcp_server) -> None:
    """``delete_container`` with a malformed id raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("delete_container", {"container_id": "bad"})
    assert _raised_tool_error(exc_info)


# --------------------------------------------------------------------------- #
# Food-memory tools.
# --------------------------------------------------------------------------- #


@pytest.mark.asyncio
async def test_remember_with_aliases_then_list_and_forget(mcp_server) -> None:
    """``remember_food`` seeds aliases; ``list_remembered_foods`` shows it; ``forget_food`` removes it."""
    async with Client(mcp_server) as client:
        remembered = await client.call_tool(
            "remember_food",
            {
                "name": "almond butter",
                "fdc_id": 4242,
                "usda_description": "Almond butter, plain",
                "basis": "per_100g",
                "calories": 614,
                "protein_g": 21.0,
                "carbs_g": 20.0,
                "fat_g": 56.0,
                "aliases": ["the almond spread"],
            },
        )
        assert "the almond spread" in remembered.structured_content["aliases"]

        listed = await client.call_tool("list_remembered_foods", {})
        assert any(r["name"] == "almond butter" for r in listed.structured_content["result"])

        forgotten = await client.call_tool("forget_food", {"name": "almond butter"})
    assert forgotten.structured_content["deleted"] is True


@pytest.mark.asyncio
async def test_remember_food_duplicate_alias_raises_tool_error(mcp_server) -> None:
    """``remember_food`` rejects an alias already claimed by another memory entry."""
    async with Client(mcp_server) as client:
        await client.call_tool(
            "remember_food",
            {
                "name": "food one",
                "fdc_id": 1,
                "usda_description": "One",
                "basis": "per_100g",
                "calories": 10,
                "protein_g": 1.0,
                "carbs_g": 1.0,
                "fat_g": 1.0,
                "aliases": ["shared alias"],
            },
        )
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "remember_food",
                {
                    "name": "food two",
                    "fdc_id": 2,
                    "usda_description": "Two",
                    "basis": "per_100g",
                    "calories": 20,
                    "protein_g": 2.0,
                    "carbs_g": 2.0,
                    "fat_g": 2.0,
                    "aliases": ["shared alias"],
                },
            )
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_add_food_alias_equal_to_name_returns_entry_unchanged(mcp_server) -> None:
    """``add_food_alias`` with the canonical name as alias returns the entry without adding it."""
    async with Client(mcp_server) as client:
        await client.call_tool(
            "remember_food",
            {
                "name": "cottage cheese",
                "fdc_id": 555,
                "usda_description": "Cottage cheese",
                "basis": "per_100g",
                "calories": 98,
                "protein_g": 11.0,
                "carbs_g": 3.4,
                "fat_g": 4.3,
            },
        )
        result = await client.call_tool(
            "add_food_alias", {"name": "cottage cheese", "alias": "cottage cheese"}
        )
    assert result.structured_content["aliases"] == []


@pytest.mark.asyncio
async def test_add_food_alias_missing_entry_raises_tool_error(mcp_server) -> None:
    """``add_food_alias`` on an unknown name raises 'Food memory not found'."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("add_food_alias", {"name": "nonexistent food", "alias": "x"})
    assert _raised_tool_error(exc_info)
    assert "not found" in str(exc_info.value).lower()


@pytest.mark.asyncio
async def test_add_food_alias_empty_after_normalization_raises_tool_error(mcp_server) -> None:
    """``add_food_alias`` with an alias that normalizes to empty raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("add_food_alias", {"name": "whatever", "alias": "   "})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_remove_food_alias_drops_alias(mcp_server) -> None:
    """``remove_food_alias`` removes a previously added alias from the entry."""
    async with Client(mcp_server) as client:
        await client.call_tool(
            "remember_food",
            {
                "name": "olive oil",
                "fdc_id": 9001,
                "usda_description": "Olive oil",
                "basis": "per_100g",
                "calories": 884,
                "protein_g": 0.0,
                "carbs_g": 0.0,
                "fat_g": 100.0,
                "aliases": ["evoo"],
            },
        )
        removed = await client.call_tool(
            "remove_food_alias", {"name": "olive oil", "alias": "evoo"}
        )
    assert "evoo" not in removed.structured_content["aliases"]


@pytest.mark.asyncio
async def test_remove_food_alias_missing_entry_raises_tool_error(mcp_server) -> None:
    """``remove_food_alias`` on an unknown name raises 'Food memory not found'."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("remove_food_alias", {"name": "ghost food", "alias": "x"})
    assert _raised_tool_error(exc_info)


# --------------------------------------------------------------------------- #
# Meal tools: CRUD, items, update/delete, errors.
# --------------------------------------------------------------------------- #


@pytest.mark.asyncio
async def test_list_meals_returns_summaries(mcp_server) -> None:
    """``list_meals`` returns a lightweight summary including aggregate totals."""
    async with Client(mcp_server) as client:
        await client.call_tool(
            "create_meal", {"name": "Summary Meal", "items": [dict(_SIMPLE_MEAL_ITEM)]}
        )
        listed = await client.call_tool("list_meals", {})
    rows = listed.structured_content["result"]
    summary = next(r for r in rows if r["name"] == "Summary Meal")
    assert summary["item_count"] == 1
    assert summary["total_calories"] == 200


@pytest.mark.asyncio
async def test_get_meal_by_name(mcp_server) -> None:
    """``get_meal`` looks a meal up by name when no id is given."""
    async with Client(mcp_server) as client:
        await client.call_tool(
            "create_meal", {"name": "Named Meal", "items": [dict(_SIMPLE_MEAL_ITEM)]}
        )
        fetched = await client.call_tool("get_meal", {"name": "Named Meal"})
    assert fetched.structured_content["name"] == "Named Meal"


@pytest.mark.asyncio
async def test_get_meal_requires_exactly_one_selector(mcp_server) -> None:
    """``get_meal`` with neither id nor name raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("get_meal", {})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_get_meal_invalid_id_raises_tool_error(mcp_server) -> None:
    """``get_meal`` with a malformed meal_id raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("get_meal", {"meal_id": "not-uuid"})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_get_meal_not_found_raises_tool_error(mcp_server) -> None:
    """``get_meal`` on an unknown id raises 'Meal not found'."""
    import uuid

    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("get_meal", {"meal_id": str(uuid.uuid4())})
    assert _raised_tool_error(exc_info)
    assert "not found" in str(exc_info.value).lower()


@pytest.mark.asyncio
async def test_create_meal_duplicate_name_raises_tool_error(mcp_server) -> None:
    """``create_meal`` rejects a second meal with a duplicate name."""
    async with Client(mcp_server) as client:
        await client.call_tool(
            "create_meal", {"name": "Unique Meal", "items": [dict(_SIMPLE_MEAL_ITEM)]}
        )
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "create_meal", {"name": "Unique Meal", "items": [dict(_SIMPLE_MEAL_ITEM)]}
            )
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_update_meal_changes_name_and_notes(mcp_server) -> None:
    """``update_meal`` updates name and notes and returns the updated meal."""
    async with Client(mcp_server) as client:
        created = await client.call_tool(
            "create_meal", {"name": "Old Meal", "items": [dict(_SIMPLE_MEAL_ITEM)]}
        )
        meal_id = created.structured_content["id"]
        updated = await client.call_tool(
            "update_meal", {"meal_id": meal_id, "name": "New Meal", "notes": "tweaked"}
        )
    assert updated.structured_content["name"] == "New Meal"
    assert updated.structured_content["notes"] == "tweaked"


@pytest.mark.asyncio
async def test_update_meal_invalid_id_raises_tool_error(mcp_server) -> None:
    """``update_meal`` with a malformed id raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("update_meal", {"meal_id": "bad", "name": "X"})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_update_meal_not_found_raises_tool_error(mcp_server) -> None:
    """``update_meal`` on an unknown id raises 'Meal not found'."""
    import uuid

    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("update_meal", {"meal_id": str(uuid.uuid4()), "name": "X"})
    assert _raised_tool_error(exc_info)
    assert "not found" in str(exc_info.value).lower()


@pytest.mark.asyncio
async def test_delete_meal_succeeds(mcp_server) -> None:
    """``delete_meal`` removes a meal and reports deleted=True."""
    async with Client(mcp_server) as client:
        created = await client.call_tool(
            "create_meal", {"name": "Disposable", "items": [dict(_SIMPLE_MEAL_ITEM)]}
        )
        meal_id = created.structured_content["id"]
        deleted = await client.call_tool("delete_meal", {"meal_id": meal_id})
    assert deleted.structured_content["deleted"] is True


@pytest.mark.asyncio
async def test_delete_meal_invalid_id_raises_tool_error(mcp_server) -> None:
    """``delete_meal`` with a malformed id raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("delete_meal", {"meal_id": "bad"})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_add_update_delete_meal_item(mcp_server) -> None:
    """``add_meal_item``/``update_meal_item``/``delete_meal_item`` round-trip on a meal."""
    async with Client(mcp_server) as client:
        created = await client.call_tool(
            "create_meal", {"name": "Item Meal", "items": [dict(_SIMPLE_MEAL_ITEM)]}
        )
        meal_id = created.structured_content["id"]

        added = await client.call_tool(
            "add_meal_item",
            {
                "meal_id": meal_id,
                "item": {
                    "display_name": "Beans",
                    "quantity_text": "1 cup",
                    "usda_fdc_id": 800,
                    "usda_description": "Black beans",
                    "calories": 220,
                    "protein_g": 15.0,
                    "carbs_g": 40.0,
                    "fat_g": 1.0,
                },
            },
        )
        item_id = added.structured_content["id"]
        assert added.structured_content["display_name"] == "Beans"

        updated = await client.call_tool(
            "update_meal_item",
            {
                "meal_id": meal_id,
                "meal_item_id": item_id,
                "calories": 230,
                "display_name": "More Beans",
            },
        )
        assert updated.structured_content["calories"] == 230
        assert updated.structured_content["display_name"] == "More Beans"

        deleted = await client.call_tool(
            "delete_meal_item", {"meal_id": meal_id, "meal_item_id": item_id}
        )
    assert deleted.structured_content["deleted"] is True


@pytest.mark.asyncio
async def test_add_meal_item_invalid_meal_id_raises_tool_error(mcp_server) -> None:
    """``add_meal_item`` with a malformed meal_id raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "add_meal_item",
                {
                    "meal_id": "bad",
                    "item": {
                        "display_name": "X",
                        "quantity_text": "1",
                        "usda_fdc_id": 1,
                        "usda_description": "x",
                        "calories": 1,
                        "protein_g": 0.0,
                        "carbs_g": 0.0,
                        "fat_g": 0.0,
                    },
                },
            )
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_add_meal_item_dual_source_raises_tool_error(mcp_server) -> None:
    """``add_meal_item`` rejects an item that sets both usda_fdc_id and custom_food_id."""
    import uuid

    async with Client(mcp_server) as client:
        created = await client.call_tool(
            "create_meal", {"name": "Dual Meal", "items": [dict(_SIMPLE_MEAL_ITEM)]}
        )
        meal_id = created.structured_content["id"]
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "add_meal_item",
                {
                    "meal_id": meal_id,
                    "item": {
                        "display_name": "Bad",
                        "quantity_text": "1",
                        "usda_fdc_id": 1,
                        "usda_description": "x",
                        "custom_food_id": str(uuid.uuid4()),
                        "calories": 1,
                        "protein_g": 0.0,
                        "carbs_g": 0.0,
                        "fat_g": 0.0,
                    },
                },
            )
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_add_meal_item_meal_not_found_raises_tool_error(mcp_server) -> None:
    """``add_meal_item`` on an unknown (well-formed) meal id raises 'Meal not found'."""
    import uuid

    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "add_meal_item",
                {
                    "meal_id": str(uuid.uuid4()),
                    "item": {
                        "display_name": "X",
                        "quantity_text": "1",
                        "usda_fdc_id": 1,
                        "usda_description": "x",
                        "calories": 1,
                        "protein_g": 0.0,
                        "carbs_g": 0.0,
                        "fat_g": 0.0,
                    },
                },
            )
    assert _raised_tool_error(exc_info)
    assert "not found" in str(exc_info.value).lower()


@pytest.mark.asyncio
async def test_update_meal_item_invalid_ids_raise_tool_error(mcp_server) -> None:
    """``update_meal_item`` with malformed ids raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "update_meal_item", {"meal_id": "bad", "meal_item_id": "worse", "calories": 1}
            )
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_update_meal_item_unknown_item_raises_tool_error(mcp_server) -> None:
    """``update_meal_item`` on a valid meal but unknown item id raises 'Meal item not found'."""
    import uuid

    async with Client(mcp_server) as client:
        created = await client.call_tool(
            "create_meal", {"name": "Edit Meal", "items": [dict(_SIMPLE_MEAL_ITEM)]}
        )
        meal_id = created.structured_content["id"]
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "update_meal_item",
                {"meal_id": meal_id, "meal_item_id": str(uuid.uuid4()), "calories": 1},
            )
    assert _raised_tool_error(exc_info)
    assert "not found" in str(exc_info.value).lower()


@pytest.mark.asyncio
async def test_update_meal_item_meal_not_found_raises_tool_error(mcp_server) -> None:
    """``update_meal_item`` on an unknown (well-formed) meal id raises 'Meal not found'."""
    import uuid

    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "update_meal_item",
                {
                    "meal_id": str(uuid.uuid4()),
                    "meal_item_id": str(uuid.uuid4()),
                    "calories": 1,
                },
            )
    assert _raised_tool_error(exc_info)
    assert "not found" in str(exc_info.value).lower()


@pytest.mark.asyncio
async def test_add_meal_alias_equal_to_name_is_no_op(mcp_server) -> None:
    """``add_meal_alias`` with the canonical name as alias returns the meal with no alias added."""
    async with Client(mcp_server) as client:
        created = await client.call_tool(
            "create_meal", {"name": "Canonical Meal", "items": [dict(_SIMPLE_MEAL_ITEM)]}
        )
        meal_id = created.structured_content["id"]
        result = await client.call_tool(
            "add_meal_alias", {"meal_id": meal_id, "alias": "Canonical Meal"}
        )
    assert result.structured_content["aliases"] == []


@pytest.mark.asyncio
async def test_delete_meal_item_invalid_ids_raise_tool_error(mcp_server) -> None:
    """``delete_meal_item`` with malformed ids raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("delete_meal_item", {"meal_id": "bad", "meal_item_id": "worse"})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_delete_meal_item_meal_not_found_raises_tool_error(mcp_server) -> None:
    """``delete_meal_item`` on an unknown meal raises 'Meal not found'."""
    import uuid

    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "delete_meal_item",
                {"meal_id": str(uuid.uuid4()), "meal_item_id": str(uuid.uuid4())},
            )
    assert _raised_tool_error(exc_info)
    assert "not found" in str(exc_info.value).lower()


@pytest.mark.asyncio
async def test_add_meal_alias_invalid_id_raises_tool_error(mcp_server) -> None:
    """``add_meal_alias`` with a malformed meal_id raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("add_meal_alias", {"meal_id": "bad", "alias": "x"})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_add_meal_alias_empty_after_normalization_raises_tool_error(mcp_server) -> None:
    """``add_meal_alias`` with an alias that normalizes to empty raises a ToolError."""
    async with Client(mcp_server) as client:
        created = await client.call_tool(
            "create_meal", {"name": "Alias Meal", "items": [dict(_SIMPLE_MEAL_ITEM)]}
        )
        meal_id = created.structured_content["id"]
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("add_meal_alias", {"meal_id": meal_id, "alias": "   "})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_add_meal_alias_duplicate_across_meals_raises_tool_error(mcp_server) -> None:
    """``add_meal_alias`` rejects an alias already used as another meal's name."""
    async with Client(mcp_server) as client:
        await client.call_tool(
            "create_meal", {"name": "First Meal", "items": [dict(_SIMPLE_MEAL_ITEM)]}
        )
        second_item = dict(_SIMPLE_MEAL_ITEM, usda_fdc_id=701)
        second = await client.call_tool(
            "create_meal", {"name": "Second Meal", "items": [second_item]}
        )
        second_id = second.structured_content["id"]
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("add_meal_alias", {"meal_id": second_id, "alias": "First Meal"})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_remove_meal_alias_drops_alias(mcp_server) -> None:
    """``remove_meal_alias`` removes a previously added alias from the meal."""
    async with Client(mcp_server) as client:
        created = await client.call_tool(
            "create_meal",
            {
                "name": "Removable Alias",
                "aliases": ["temp alias"],
                "items": [dict(_SIMPLE_MEAL_ITEM)],
            },
        )
        meal_id = created.structured_content["id"]
        removed = await client.call_tool(
            "remove_meal_alias", {"meal_id": meal_id, "alias": "temp alias"}
        )
    assert "temp alias" not in removed.structured_content["aliases"]


@pytest.mark.asyncio
async def test_remove_meal_alias_invalid_id_raises_tool_error(mcp_server) -> None:
    """``remove_meal_alias`` with a malformed meal_id raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("remove_meal_alias", {"meal_id": "bad", "alias": "x"})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_remove_meal_alias_missing_meal_raises_tool_error(mcp_server) -> None:
    """``remove_meal_alias`` on an unknown meal id raises 'Meal not found'."""
    import uuid

    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "remove_meal_alias", {"meal_id": str(uuid.uuid4()), "alias": "x"}
            )
    assert _raised_tool_error(exc_info)
    assert "not found" in str(exc_info.value).lower()


@pytest.mark.asyncio
async def test_log_meal_invalid_id_raises_tool_error(mcp_server) -> None:
    """``log_meal`` with a malformed meal_id raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("log_meal", {"meal_id": "bad"})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_log_meal_unknown_meal_raises_tool_error(mcp_server) -> None:
    """``log_meal`` on a well-formed but unknown meal id surfaces the service 404 as a ToolError."""
    import uuid

    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("log_meal", {"meal_id": str(uuid.uuid4())})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_log_meal_with_backdated_consumed_at(mcp_server) -> None:
    """``log_meal`` accepts a YYYY-MM-DD ``consumed_at`` and buckets entries on that date."""
    async with Client(mcp_server) as client:
        created = await client.call_tool(
            "create_meal", {"name": "Backdated Meal", "items": [dict(_SIMPLE_MEAL_ITEM)]}
        )
        meal_id = created.structured_content["id"]
        logged = await client.call_tool(
            "log_meal", {"meal_id": meal_id, "consumed_at": "2026-01-15"}
        )
    payload = logged.structured_content
    assert len(payload["entries"]) == 1
    assert payload["entries"][0]["consumed_at"].startswith("2026-01-15")


# --------------------------------------------------------------------------- #
# Food + targets tools.
# --------------------------------------------------------------------------- #


@pytest.mark.asyncio
async def test_log_food_requires_exactly_one_source(mcp_server) -> None:
    """``log_food`` with neither fdc_id nor custom_food_id raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "log_food",
                {
                    "display_name": "No source",
                    "quantity_text": "1",
                    "calories": 10,
                    "protein_g": 1.0,
                    "carbs_g": 1.0,
                    "fat_g": 1.0,
                },
            )
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_log_food_usda_without_description_raises_tool_error(mcp_server) -> None:
    """``log_food`` with fdc_id but no usda_description raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "log_food",
                {
                    "display_name": "Missing desc",
                    "quantity_text": "1",
                    "calories": 10,
                    "protein_g": 1.0,
                    "carbs_g": 1.0,
                    "fat_g": 1.0,
                    "fdc_id": 123,
                },
            )
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_log_food_invalid_custom_food_id_raises_tool_error(mcp_server) -> None:
    """``log_food`` with a malformed custom_food_id raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "log_food",
                {
                    "display_name": "Bad cf",
                    "quantity_text": "1",
                    "calories": 10,
                    "protein_g": 1.0,
                    "carbs_g": 1.0,
                    "fat_g": 1.0,
                    "custom_food_id": "not-a-uuid",
                },
            )
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_log_food_unowned_custom_food_id_raises_tool_error(mcp_server) -> None:
    """``log_food`` referencing a custom_food_id that does not exist raises a ToolError."""
    import uuid

    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool(
                "log_food",
                {
                    "display_name": "Phantom cf",
                    "quantity_text": "1",
                    "calories": 10,
                    "protein_g": 1.0,
                    "carbs_g": 1.0,
                    "fat_g": 1.0,
                    "custom_food_id": str(uuid.uuid4()),
                },
            )
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_delete_entry_round_trip(mcp_server) -> None:
    """``log_food`` then ``delete_entry`` removes the entry and reports deleted=True."""
    async with Client(mcp_server) as client:
        logged = await client.call_tool(
            "log_food",
            {
                "display_name": "Banana",
                "quantity_text": "1 medium",
                "calories": 105,
                "protein_g": 1.3,
                "carbs_g": 27.0,
                "fat_g": 0.4,
                "fdc_id": 1105314,
                "usda_description": "Banana, raw",
            },
        )
        entry_id = logged.structured_content["entry"]["id"]
        deleted = await client.call_tool("delete_entry", {"entry_id": entry_id})
    assert deleted.structured_content["deleted"] is True


@pytest.mark.asyncio
async def test_delete_entry_invalid_id_raises_tool_error(mcp_server) -> None:
    """``delete_entry`` with a malformed id raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("delete_entry", {"entry_id": "bad"})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_get_targets_none_then_set(mcp_server) -> None:
    """``get_targets`` returns null before any profile, then the set values after ``set_targets``."""
    async with Client(mcp_server) as client:
        before = await client.call_tool("get_targets", {})
        assert before.structured_content.get("result") is None

        await client.call_tool(
            "set_targets",
            {"calories": 2200, "protein_g": 160.0, "carbs_g": 220.0, "fat_g": 70.0},
        )
        after = await client.call_tool("get_targets", {})
    payload = after.structured_content["result"]
    assert payload["calories"] == 2200
    assert payload["protein_g"] == 160.0


@pytest.mark.asyncio
async def test_get_day_invalid_date_raises_tool_error(mcp_server) -> None:
    """``get_day`` with a malformed date string raises a ToolError."""
    async with Client(mcp_server) as client:
        with pytest.raises(Exception) as exc_info:
            await client.call_tool("get_day", {"date": "15-01-2026"})
    assert _raised_tool_error(exc_info)


@pytest.mark.asyncio
async def test_get_day_explicit_date_with_entries(mcp_server) -> None:
    """``get_day`` for an explicit date returns the entries logged on that date."""
    async with Client(mcp_server) as client:
        await client.call_tool(
            "log_food",
            {
                "display_name": "Dated Oats",
                "quantity_text": "1 bowl",
                "calories": 300,
                "protein_g": 12.0,
                "carbs_g": 50.0,
                "fat_g": 6.0,
                "fdc_id": 111,
                "usda_description": "Oats",
                "consumed_at": "2026-02-10",
            },
        )
        result = await client.call_tool("get_day", {"date": "2026-02-10"})
    payload = result.structured_content
    assert payload["consumed"]["calories"] == 300
    assert len(payload["entries"]) == 1
