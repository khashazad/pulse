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
from pulse_server.services.foods_service import group_foods, list_foods_with_portions, ungroup_food
from pulse_server.services.normalize import normalize_name

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
            name=name,
            basis="per_unit",
            calories=calories,
            protein_g=0.0,
            carbs_g=float(calories) / 4,
            fat_g=0.0,
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
                session,
                USER,
                FoodCreate(
                    name="Apple", portion_ids=[small, medium, large], default_portion_id=medium
                ),
                DateTimeValue.now(tz=UTC),
            )

        assert food["default_portion_id"] == medium
        labels = sorted(p["portion_label"] for p in portions)
        assert labels == ["large", "medium", "small"]
        assert {
            normalize_name("small apple"),
            normalize_name("medium apple"),
            normalize_name("large apple"),
        } <= set(aliases)

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
            await session.execute(
                text(
                    "INSERT INTO daily_logs (id, user_key, log_date) VALUES (:i, :u, CURRENT_DATE)"
                ),
                {"i": str(log_id), "u": USER},
            )
            entry_id = uuid.uuid4()
            await session.execute(
                text(
                    "INSERT INTO food_entries (id, daily_log_id, user_key, entry_group_id, "
                    "display_name, quantity_text, custom_food_id, calories, protein_g, carbs_g, "
                    "fat_g, consumed_at) VALUES (:id, :log, :u, :grp, 'medium apple', '1 apple', "
                    ":cf, 95, 0, 24, 0, now())"
                ),
                {
                    "id": str(entry_id),
                    "log": str(log_id),
                    "u": USER,
                    "grp": str(uuid.uuid4()),
                    "cf": str(medium),
                },
            )

        async with transaction(session):
            await group_foods(
                session,
                USER,
                FoodCreate(name="Apple", portion_ids=[medium]),
                DateTimeValue.now(tz=UTC),
            )

        row = (
            (
                await session.execute(
                    select(food_entries.c.calories, food_entries.c.custom_food_id).where(
                        food_entries.c.id == entry_id
                    )
                )
            )
            .mappings()
            .one()
        )
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
                session,
                USER,
                FoodCreate(
                    name="Apple",
                    portion_ids=[small, medium],
                    default_portion_id=medium,
                    aliases=["apples"],
                ),
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
            await group_foods(
                session,
                USER,
                FoodCreate(name="Apple", portion_ids=[small, medium]),
                DateTimeValue.now(tz=UTC),
            )

        foods, standalones = await list_foods_with_portions(session, USER)
        assert len(foods) == 1
        _food, portions, _aliases = foods[0]
        assert len(portions) == 2
        assert [s["id"] for s in standalones] == [bar]


@pytest.mark.asyncio
async def test_remove_portion_restores_standalone_memory(maker):
    async with maker() as session:
        async with transaction(session):
            small = await _make_custom_food(session, "small apple", 70)
            medium = await _make_custom_food(session, "medium apple", 95)
        async with transaction(session):
            food, _, _ = await group_foods(
                session,
                USER,
                FoodCreate(name="Apple", portion_ids=[small, medium], default_portion_id=medium),
                DateTimeValue.now(tz=UTC),
            )
        # After grouping, "small apple" has no standalone memory row (folded into Apple).
        mem_repo = FoodMemoryRepository(session)
        cf_repo = CustomFoodsRepository(session)
        from pulse_server.services.foods_service import detach_portion

        async with transaction(session):
            await detach_portion(session, USER, food["id"], small, DateTimeValue.now(tz=UTC))
        # The detached portion is standalone and resolvable again.
        assert (await cf_repo.get_by_id(small, USER))["food_id"] is None
        hit = await mem_repo.get_by_name(USER, "small apple")
        assert hit is not None and hit["custom_food_id"] == small and hit["food_id"] is None


@pytest.mark.asyncio
async def test_upsert_custom_reclaims_food_targeted_name(maker):
    # Directly exercises FIX 1: upserting a custom-target row over a name that
    # currently has a Food target must null food_id (no constraint violation).
    async with maker() as session:
        async with transaction(session):
            medium = await _make_custom_food(session, "medium apple", 95)
        async with transaction(session):
            _food, _, _ = await group_foods(
                session,
                USER,
                FoodCreate(name="Apple", portion_ids=[medium], default_portion_id=medium),
                DateTimeValue.now(tz=UTC),
            )
        mem_repo = FoodMemoryRepository(session)
        # "apple" currently resolves to the Food (food_id set). Re-point it to a custom food.
        async with transaction(session):
            row = await mem_repo.upsert_custom(
                user_key=USER,
                name="Apple",
                normalized_name="apple",
                custom_food_id=medium,
                now=DateTimeValue.now(tz=UTC),
            )
        assert row["custom_food_id"] == medium
        assert row["food_id"] is None


@pytest.mark.asyncio
async def test_update_food_rename_moves_memory_and_preserves_aliases(maker):
    from pulse_server.services.foods_service import update_food as update_food_service

    async with maker() as session:
        async with transaction(session):
            small = await _make_custom_food(session, "small apple", 70)
            medium = await _make_custom_food(session, "medium apple", 95)
        async with transaction(session):
            food, _, _ = await group_foods(
                session,
                USER,
                FoodCreate(
                    name="Apple",
                    portion_ids=[small, medium],
                    default_portion_id=medium,
                    aliases=["apples"],
                ),
                DateTimeValue.now(tz=UTC),
            )
        async with transaction(session):
            await update_food_service(
                session, USER, food["id"], {"name": "Green Apple"}, None, DateTimeValue.now(tz=UTC)
            )

        mem_repo = FoodMemoryRepository(session)
        green = await mem_repo.get_by_name(USER, "green apple")
        assert green is not None and green["food_id"] == food["id"]
        assert "apples" in (green.get("aliases") or [])
        # The old canonical name no longer has its own memory row.
        old = await mem_repo.get_by_name(USER, "apple")
        assert old is None or old["food_id"] == food["id"]


@pytest.mark.asyncio
async def test_attach_portion_links_and_derives_label(maker):
    from pulse_server.services.foods_service import attach_portion

    async with maker() as session:
        async with transaction(session):
            small = await _make_custom_food(session, "small apple", 70)
            huge = await _make_custom_food(session, "huge apple", 130)
        async with transaction(session):
            food, _, _ = await group_foods(
                session,
                USER,
                FoodCreate(name="Apple", portion_ids=[small], default_portion_id=small),
                DateTimeValue.now(tz=UTC),
            )
        async with transaction(session):
            await attach_portion(session, USER, food["id"], huge, None, DateTimeValue.now(tz=UTC))

        cf_repo = CustomFoodsRepository(session)
        attached = await cf_repo.get_by_id(huge, USER)
        assert attached["food_id"] == food["id"]
        assert attached["portion_label"] == "huge"


@pytest.mark.asyncio
async def test_upsert_usda_reclaims_food_targeted_name(maker):
    # FIX F1: USDA upsert over a name that currently targets a Food must null food_id.
    async with maker() as session:
        async with transaction(session):
            medium = await _make_custom_food(session, "medium apple", 95)
        async with transaction(session):
            await group_foods(
                session,
                USER,
                FoodCreate(name="Apple", portion_ids=[medium], default_portion_id=medium),
                DateTimeValue.now(tz=UTC),
            )
        mem_repo = FoodMemoryRepository(session)
        async with transaction(session):
            row = await mem_repo.upsert_usda(
                user_key=USER,
                name="Apple",
                normalized_name="apple",
                usda_fdc_id=171688,
                usda_description="Apples, raw",
                basis="per_100g",
                serving_size=None,
                serving_size_unit=None,
                calories=52,
                protein_g=0.3,
                carbs_g=14.0,
                fat_g=0.2,
                now=DateTimeValue.now(tz=UTC),
            )
        assert row["usda_fdc_id"] == 171688
        assert row["food_id"] is None


@pytest.mark.asyncio
async def test_resolve_food_by_name_grouped_food_returns_food_type(maker):
    # FIX F2 (updated Task 2): resolving a grouped Food name now returns type='food'
    # with the Food's portions rather than crashing or returning 'none'.
    from pulse_server.services.food_memory_service import resolve_food_by_name

    async with maker() as session:
        async with transaction(session):
            medium = await _make_custom_food(session, "medium apple", 95)
        async with transaction(session):
            food, _, _ = await group_foods(
                session,
                USER,
                FoodCreate(name="Apple", portion_ids=[medium], default_portion_id=medium),
                DateTimeValue.now(tz=UTC),
            )
        resolved = await resolve_food_by_name(session, USER, "apple")
        assert resolved.type == "food"
        assert resolved.food_id == food["id"]
        assert resolved.default_portion_id == medium
        assert len(resolved.portions) == 1
        assert resolved.portions[0].custom_food_id == medium


@pytest.mark.asyncio
async def test_detach_portion_rejects_portion_from_other_food(maker):
    # FIX F3: detaching a portion that belongs to a different Food 404s, no corruption.
    from pulse_server.services.foods_service import detach_portion

    async with maker() as session:
        async with transaction(session):
            a = await _make_custom_food(session, "small apple", 70)
            b = await _make_custom_food(session, "small banana", 90)
        async with transaction(session):
            apple, _, _ = await group_foods(
                session,
                USER,
                FoodCreate(name="Apple", portion_ids=[a], default_portion_id=a),
                DateTimeValue.now(tz=UTC),
            )
            banana, _, _ = await group_foods(
                session,
                USER,
                FoodCreate(name="Banana", portion_ids=[b], default_portion_id=b),
                DateTimeValue.now(tz=UTC),
            )
        import pytest as _pytest
        from fastapi import HTTPException

        with _pytest.raises(HTTPException) as exc:
            async with transaction(session):
                await detach_portion(session, USER, apple["id"], b, DateTimeValue.now(tz=UTC))
        assert exc.value.status_code == 404
        # Banana's portion is untouched.
        cf_repo = CustomFoodsRepository(session)
        assert (await cf_repo.get_by_id(b, USER))["food_id"] == banana["id"]


@pytest.mark.asyncio
async def test_detach_default_portion_repoints_default(maker):
    # FIX F4: detaching the default portion repoints default_portion_id to a remaining one.
    from pulse_server.services.foods_service import detach_portion

    async with maker() as session:
        async with transaction(session):
            small = await _make_custom_food(session, "small apple", 70)
            medium = await _make_custom_food(session, "medium apple", 95)
        async with transaction(session):
            food, _, _ = await group_foods(
                session,
                USER,
                FoodCreate(name="Apple", portion_ids=[small, medium], default_portion_id=small),
                DateTimeValue.now(tz=UTC),
            )
        async with transaction(session):
            await detach_portion(session, USER, food["id"], small, DateTimeValue.now(tz=UTC))
        foods_repo = FoodsRepository(session)
        refreshed = await foods_repo.get_by_id(food["id"], USER)
        assert refreshed["default_portion_id"] == medium


@pytest.mark.asyncio
async def test_attach_portion_rolls_name_into_food_aliases(maker):
    # FIX F5: attaching a portion folds its name into the Food's aliases.
    from pulse_server.services.foods_service import attach_portion

    async with maker() as session:
        async with transaction(session):
            small = await _make_custom_food(session, "small apple", 70)
            huge = await _make_custom_food(session, "huge apple", 130)
        async with transaction(session):
            food, _, _ = await group_foods(
                session,
                USER,
                FoodCreate(name="Apple", portion_ids=[small], default_portion_id=small),
                DateTimeValue.now(tz=UTC),
            )
        async with transaction(session):
            await attach_portion(session, USER, food["id"], huge, None, DateTimeValue.now(tz=UTC))
        mem_repo = FoodMemoryRepository(session)
        food_mem = await mem_repo.get_by_food_id(USER, food["id"])
        assert "huge apple" in (food_mem.get("aliases") or [])


@pytest.mark.asyncio
async def test_resolve_food_by_name_returns_food_with_portions(maker):
    from pulse_server.services.food_memory_service import resolve_food_by_name

    async with maker() as session:
        async with transaction(session):
            small = await _make_custom_food(session, "small apple", 70)
            large = await _make_custom_food(session, "large apple", 110)
        async with transaction(session):
            food, _, _ = await group_foods(
                session,
                USER,
                FoodCreate(name="Apple", portion_ids=[small, large], default_portion_id=small),
                DateTimeValue.now(tz=UTC),
            )
        resolved = await resolve_food_by_name(session, USER, "apple")
        assert resolved.type == "food"
        assert resolved.food_id == food["id"]
        assert resolved.default_portion_id == small
        labels = sorted(p.label for p in resolved.portions)
        assert labels == ["large", "small"]
        ids = {p.custom_food_id for p in resolved.portions}
        assert ids == {small, large}


@pytest.mark.asyncio
async def test_resolve_food_by_name_empty_food_is_graceful_miss(maker):
    # A Food whose only portion was detached has nothing loggable; resolving its
    # name must be a graceful miss (type="none"), not an unactionable type="food".
    from pulse_server.services.food_memory_service import resolve_food_by_name
    from pulse_server.services.foods_service import detach_portion

    async with maker() as session:
        async with transaction(session):
            only = await _make_custom_food(session, "small apple", 70)
        async with transaction(session):
            food, _, _ = await group_foods(
                session,
                USER,
                FoodCreate(name="Apple", portion_ids=[only], default_portion_id=only),
                DateTimeValue.now(tz=UTC),
            )
        async with transaction(session):
            await detach_portion(session, USER, food["id"], only, DateTimeValue.now(tz=UTC))
        resolved = await resolve_food_by_name(session, USER, "apple")
        assert resolved.type == "none"
