from __future__ import annotations

import os
import uuid
from datetime import datetime as DateTimeValue
from datetime import timezone as TimezoneValue

import pytest
import pytest_asyncio
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from diet_tracker_server.db import to_sqlalchemy_url, transaction
from diet_tracker_server.models import (
    CustomFoodCreate,
    MealCreate,
    MealItemCreate,
)
from diet_tracker_server.repositories.custom_foods import CustomFoodsRepository
from diet_tracker_server.repositories.entries import EntriesRepository
from diet_tracker_server.repositories.food_memory import FoodMemoryRepository
from diet_tracker_server.repositories.meals import MealsRepository
from diet_tracker_server.services.custom_foods_service import upsert_custom_food_and_remember
from diet_tracker_server.services.food_memory_service import resolve_food_by_name
from diet_tracker_server.services.meals_service import create_meal_with_items, log_meal

pytestmark = pytest.mark.integration


def _integration_database_url() -> str:
    raw_url = os.getenv("TEST_DATABASE_URL")
    if raw_url is None:
        pytest.skip("Set TEST_DATABASE_URL to run integration tests")
    return to_sqlalchemy_url(raw_url)


async def _truncate(engine) -> None:
    table_names = [
        "food_entries",
        "meal_items",
        "meals",
        "food_memory",
        "custom_foods",
        "daily_logs",
        "daily_target_profile",
    ]
    async with engine.begin() as conn:
        await conn.exec_driver_sql(
            f"TRUNCATE TABLE {', '.join(table_names)} RESTART IDENTITY CASCADE"
        )


@pytest_asyncio.fixture(scope="session")
async def session_factory() -> async_sessionmaker[AsyncSession]:
    engine = create_async_engine(_integration_database_url(), pool_pre_ping=True)
    factory: async_sessionmaker[AsyncSession] = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()


@pytest_asyncio.fixture(autouse=True)
async def clean_database(session_factory: async_sessionmaker[AsyncSession]) -> None:
    await _truncate(session_factory.kw["bind"])
    yield
    await _truncate(session_factory.kw["bind"])


@pytest_asyncio.fixture
async def session(session_factory: async_sessionmaker[AsyncSession]) -> AsyncSession:
    async with session_factory() as db_session:
        yield db_session


@pytest.mark.asyncio
async def test_save_custom_food_writes_memory_pointer(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)

    payload = CustomFoodCreate(
        name="My Wrap",
        basis="per_serving",
        serving_size=1,
        serving_size_unit="wrap",
        calories=350,
        protein_g=20,
        carbs_g=30,
        fat_g=15,
        source="photo",
    )
    async with transaction(session):
        food_row = await upsert_custom_food_and_remember(
            session=session, user_key=user_key, payload=payload, now=now
        )

    resolved = await resolve_food_by_name(session=session, user_key=user_key, name="my wrap")
    assert resolved.type == "custom_food"
    assert resolved.custom_food_id == food_row["id"]
    assert resolved.calories == 350
    assert resolved.basis == "per_serving"


@pytest.mark.asyncio
async def test_resolve_food_returns_none_when_unknown(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    resolved = await resolve_food_by_name(session=session, user_key=user_key, name="missing")
    assert resolved.type == "none"


@pytest.mark.asyncio
async def test_food_memory_usda_round_trip(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    repo = FoodMemoryRepository(session)
    async with transaction(session):
        await repo.upsert_usda(
            user_key=user_key,
            name="Greek Yogurt",
            normalized_name="greek yogurt",
            usda_fdc_id=170894,
            usda_description="Yogurt, Greek, plain, nonfat",
            basis="per_100g",
            serving_size=170,
            serving_size_unit="g",
            calories=59,
            protein_g=10.2,
            carbs_g=3.6,
            fat_g=0.4,
            now=now,
        )
    resolved = await resolve_food_by_name(session=session, user_key=user_key, name="GREEK yogurt")
    assert resolved.type == "memory_usda"
    assert resolved.usda_fdc_id == 170894
    assert resolved.calories == 59
    assert resolved.protein_g == 10.2


@pytest.mark.asyncio
async def test_food_entries_check_constraint_blocks_dual_source(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    log_date = now.date()
    custom_repo = CustomFoodsRepository(session)
    entries_repo = EntriesRepository(session)

    async with transaction(session):
        cf = await custom_repo.create(
            user_key=user_key,
            name="Test CF",
            normalized_name="test cf",
            basis="per_serving",
            serving_size=1,
            serving_size_unit="unit",
            calories=100,
            protein_g=5,
            carbs_g=10,
            fat_g=2,
            source="manual",
            notes=None,
            now=now,
        )
        log_id = entries_repo.daily_log_id(user_key=user_key, log_date=log_date)
        await entries_repo.ensure_daily_log(log_id, user_key, log_date)

    with pytest.raises(IntegrityError):
        async with transaction(session):
            await entries_repo.create_food_entry(
                entry_id=uuid.uuid4(),
                daily_log_id=log_id,
                user_key=user_key,
                entry_group_id=uuid.uuid4(),
                display_name="bad",
                quantity_text="1",
                normalized_quantity_value=None,
                normalized_quantity_unit=None,
                usda_fdc_id=12345,
                usda_description="USDA Thing",
                custom_food_id=cf["id"],
                calories=100,
                protein_g=5,
                carbs_g=10,
                fat_g=2,
                consumed_at=now,
            )


@pytest.mark.asyncio
async def test_log_meal_expands_into_food_entries(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)

    payload = MealCreate(
        name="My Breakfast",
        notes="weekday default",
        items=[
            MealItemCreate(
                display_name="oats",
                quantity_text="1 bowl",
                usda_fdc_id=200001,
                usda_description="Oats",
                calories=300,
                protein_g=10,
                carbs_g=50,
                fat_g=5,
            ),
            MealItemCreate(
                display_name="milk",
                quantity_text="1 cup",
                usda_fdc_id=200002,
                usda_description="Milk",
                calories=100,
                protein_g=8,
                carbs_g=12,
                fat_g=3,
            ),
        ],
    )
    async with transaction(session):
        meal_row, item_rows = await create_meal_with_items(
            session=session, user_key=user_key, payload=payload, now=now
        )
    assert len(item_rows) == 2
    assert [r["position"] for r in item_rows] == [0, 1]

    created_rows, day_rows = await log_meal(
        session=session, user_key=user_key, meal_id=meal_row["id"], now=now
    )
    assert len(created_rows) == 2
    assert all(r["entry_group_id"] == created_rows[0]["entry_group_id"] for r in created_rows)
    total_calories = sum(int(r["calories"]) for r in day_rows)
    assert total_calories == 400


@pytest.mark.asyncio
async def test_delete_custom_food_blocked_when_referenced(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    log_date = now.date()
    custom_repo = CustomFoodsRepository(session)
    entries_repo = EntriesRepository(session)

    async with transaction(session):
        cf = await custom_repo.create(
            user_key=user_key,
            name="Restrict Test",
            normalized_name="restrict test",
            basis="per_serving",
            serving_size=1,
            serving_size_unit="unit",
            calories=200,
            protein_g=10,
            carbs_g=20,
            fat_g=5,
            source="manual",
            notes=None,
            now=now,
        )
        log_id = entries_repo.daily_log_id(user_key=user_key, log_date=log_date)
        await entries_repo.ensure_daily_log(log_id, user_key, log_date)
        await entries_repo.create_food_entry(
            entry_id=uuid.uuid4(),
            daily_log_id=log_id,
            user_key=user_key,
            entry_group_id=uuid.uuid4(),
            display_name="restrict test",
            quantity_text="1",
            normalized_quantity_value=None,
            normalized_quantity_unit=None,
            usda_fdc_id=None,
            usda_description=None,
            custom_food_id=cf["id"],
            calories=200,
            protein_g=10,
            carbs_g=20,
            fat_g=5,
            consumed_at=now,
        )

    with pytest.raises(IntegrityError):
        async with transaction(session):
            await custom_repo.delete(cf["id"], user_key)


@pytest.mark.asyncio
async def test_meal_unique_name_per_user(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    payload = MealCreate(
        name="Lunch",
        items=[
            MealItemCreate(
                display_name="x",
                quantity_text="1",
                usda_fdc_id=1,
                usda_description="x",
                calories=10,
                protein_g=1,
                carbs_g=1,
                fat_g=1,
            )
        ],
    )
    async with transaction(session):
        await create_meal_with_items(session=session, user_key=user_key, payload=payload, now=now)

    with pytest.raises(IntegrityError):
        async with transaction(session):
            await create_meal_with_items(
                session=session, user_key=user_key, payload=payload, now=now
            )


@pytest.mark.asyncio
async def test_list_meals_includes_item_counts(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    repo = MealsRepository(session)

    payload = MealCreate(
        name="Snack",
        items=[
            MealItemCreate(
                display_name="bar",
                quantity_text="1",
                usda_fdc_id=1,
                usda_description="x",
                calories=100,
                protein_g=5,
                carbs_g=10,
                fat_g=3,
            )
        ],
    )
    async with transaction(session):
        await create_meal_with_items(session=session, user_key=user_key, payload=payload, now=now)
        await repo.create_meal(
            user_key=user_key, name="Empty", normalized_name="empty", notes=None, now=now
        )

    rows = await repo.list_meals(user_key)
    by_name = {row["normalized_name"]: row for row in rows}
    assert int(by_name["snack"]["item_count"]) == 1
    assert int(by_name["empty"]["item_count"]) == 0
