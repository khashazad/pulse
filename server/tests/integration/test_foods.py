"""Integration tests for the Foods (portion parent) feature.

Hits a real Postgres via ``TEST_DATABASE_URL``. Covers grouping (linkage, label
derivation, default portion, alias roll-up, portion-memory removal), the
ungroup round-trip (aliases pushed back onto the former default portion), the
history invariant (existing food_entries macros unchanged after grouping), and
the list shape (foods + standalones).
"""

from __future__ import annotations

import os
import uuid
from datetime import UTC
from datetime import datetime as DateTimeValue

import pytest
import pytest_asyncio
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from pulse_server.db import to_sqlalchemy_url, transaction
from pulse_server.models import CustomFoodCreate, FoodCreate
from pulse_server.repositories.custom_foods import CustomFoodsRepository
from pulse_server.repositories.food_memory import FoodMemoryRepository
from pulse_server.repositories.foods import FoodsRepository
from pulse_server.repositories.tables import food_entries
from pulse_server.services.custom_foods_service import upsert_custom_food_and_remember
from pulse_server.services.foods_service import group_foods, ungroup_food, list_foods_with_portions

pytestmark = pytest.mark.integration

USER = "test-foods-user"


def _database_url() -> str:
    raw = os.getenv("TEST_DATABASE_URL")
    if raw is None:
        pytest.skip("Set TEST_DATABASE_URL to run integration tests")
    return to_sqlalchemy_url(raw)


async def _truncate(engine) -> None:
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "TRUNCATE food_entries, meal_items, meals, food_memory, foods, "
                "custom_foods, daily_logs RESTART IDENTITY CASCADE"
            )
        )


@pytest_asyncio.fixture
async def maker():
    engine = create_async_engine(_database_url())
    await _truncate(engine)
    yield async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)
    await engine.dispose()


async def _make_custom_food(session: AsyncSession, name: str, calories: int) -> uuid.UUID:
    now = DateTimeValue.now(tz=UTC)
    row = await upsert_custom_food_and_remember(
        session=session,
        user_key=USER,
        payload=CustomFoodCreate(
            name=name, basis="per_unit", calories=calories,
            protein_g=0.0, carbs_g=float(calories) / 4, fat_g=0.0,
        ),
        now=now,
    )
    return row["id"]


@pytest.mark.asyncio
async def test_group_links_portions_and_rolls_up_aliases(maker):
    async with maker() as session:
        async with transaction(session):
            small = await _make_custom_food(session, "small apple", 70)
            medium = await _make_custom_food(session, "medium apple", 95)
            large = await _make_custom_food(session, "large apple", 110)
        async with transaction(session):
            food, portions, aliases = await group_foods(
                session, USER,
                FoodCreate(name="Apple", portion_ids=[small, medium, large],
                           default_portion_id=medium),
                DateTimeValue.now(tz=UTC),
            )

        assert food["default_portion_id"] == medium
        labels = sorted(p["portion_label"] for p in portions)
        assert labels == ["large", "medium", "small"]
        assert {"small apple", "medium apple", "large apple"} <= set(aliases)

        mem_repo = FoodMemoryRepository(session)
        assert await mem_repo.get_by_name(USER, "small apple") is not None
        food_mem = await mem_repo.get_by_food_id(USER, food["id"])
        assert food_mem is not None
        rows = await mem_repo.list_for_user(USER)
        assert all(r["custom_food_id"] is None for r in rows)


@pytest.mark.asyncio
async def test_history_unchanged_after_grouping(maker):
    async with maker() as session:
        async with transaction(session):
            medium = await _make_custom_food(session, "medium apple", 95)
            log_id = uuid.uuid4()
            await session.execute(text(
                "INSERT INTO daily_logs (id, user_key, log_date) VALUES (:i, :u, CURRENT_DATE)"
            ), {"i": str(log_id), "u": USER})
            entry_id = uuid.uuid4()
            await session.execute(text(
                "INSERT INTO food_entries (id, daily_log_id, user_key, entry_group_id, "
                "display_name, quantity_text, custom_food_id, calories, protein_g, carbs_g, "
                "fat_g, consumed_at) VALUES (:id, :log, :u, :grp, 'medium apple', '1 apple', "
                ":cf, 95, 0, 24, 0, now())"
            ), {"id": str(entry_id), "log": str(log_id), "u": USER,
                "grp": str(uuid.uuid4()), "cf": str(medium)})

        async with transaction(session):
            await group_foods(session, USER,
                              FoodCreate(name="Apple", portion_ids=[medium]),
                              DateTimeValue.now(tz=UTC))

        row = (await session.execute(
            select(food_entries.c.calories, food_entries.c.custom_food_id)
            .where(food_entries.c.id == entry_id)
        )).mappings().one()
        assert row["calories"] == 95
        assert row["custom_food_id"] == medium


@pytest.mark.asyncio
async def test_ungroup_pushes_aliases_back_to_default_portion(maker):
    async with maker() as session:
        async with transaction(session):
            small = await _make_custom_food(session, "small apple", 70)
            medium = await _make_custom_food(session, "medium apple", 95)
        async with transaction(session):
            food, _, _ = await group_foods(
                session, USER,
                FoodCreate(name="Apple", portion_ids=[small, medium],
                           default_portion_id=medium, aliases=["apples"]),
                DateTimeValue.now(tz=UTC),
            )
        async with transaction(session):
            ok = await ungroup_food(session, USER, food["id"], DateTimeValue.now(tz=UTC))

        assert ok is True
        foods_repo = FoodsRepository(session)
        assert await foods_repo.get_by_id(food["id"], USER) is None
        cf_repo = CustomFoodsRepository(session)
        assert (await cf_repo.get_by_id(medium, USER))["food_id"] is None
        mem_repo = FoodMemoryRepository(session)
        apple = await mem_repo.get_by_name(USER, "apple")
        assert apple is not None and apple["custom_food_id"] == medium
        apples = await mem_repo.get_by_name(USER, "apples")
        assert apples is not None and apples["custom_food_id"] == medium


@pytest.mark.asyncio
async def test_list_foods_with_portions_and_standalones(maker):
    async with maker() as session:
        async with transaction(session):
            small = await _make_custom_food(session, "small apple", 70)
            medium = await _make_custom_food(session, "medium apple", 95)
            bar = await _make_custom_food(session, "protein bar", 200)
        async with transaction(session):
            await group_foods(session, USER,
                              FoodCreate(name="Apple", portion_ids=[small, medium]),
                              DateTimeValue.now(tz=UTC))

        foods, standalones = await list_foods_with_portions(session, USER)
        assert len(foods) == 1
        _food, portions, _aliases = foods[0]
        assert len(portions) == 2
        assert [s["id"] for s in standalones] == [bar]
