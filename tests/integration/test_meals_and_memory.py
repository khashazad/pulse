"""Integration tests for meal templates, food-memory, and meal/entry linkage.

Covers ``custom_foods`` + ``food_memory`` round-trip via ``save_custom_food`` and
``resolve_food_by_name``; the CHECK constraint that bans a ``food_entries`` row
with both a USDA id and a ``custom_food_id``; meal creation, expansion into
``food_entries`` with stamped ``meal_id``/``meal_name``, listing with totals;
historical immutability of stamped meal name across rename and delete; and the
guarantee that the public entries endpoint ignores client-supplied
``meal_id``/``meal_name`` keys. Integration test: hits a real Postgres via
``TEST_DATABASE_URL``.
"""

from __future__ import annotations

import os
import uuid
from datetime import datetime as DateTimeValue
from datetime import timezone as TimezoneValue

import pytest
import pytest_asyncio
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from pulse_server.db import to_sqlalchemy_url, transaction
from pulse_server.models import (
    CustomFoodCreate,
    MealCreate,
    MealItemCreate,
)
from pulse_server.repositories.custom_foods import CustomFoodsRepository
from pulse_server.repositories.entries import EntriesRepository
from pulse_server.repositories.food_memory import FoodMemoryRepository
from pulse_server.repositories.meals import MealsRepository
from pulse_server.services.custom_foods_service import upsert_custom_food_and_remember
from pulse_server.services.food_memory_service import resolve_food_by_name
from pulse_server.services.meals_service import create_meal_with_items, log_meal

pytestmark = pytest.mark.integration


def _integration_database_url() -> str:
    """Resolve the SQLAlchemy URL for the integration database, skipping if unset.

    **Outputs:**
    - str: SQLAlchemy-async URL derived from ``TEST_DATABASE_URL``.

    **Exceptions:**
    - ``pytest.skip.Exception``: Raised via ``pytest.skip`` when ``TEST_DATABASE_URL`` is not set.
    """
    raw_url = os.getenv("TEST_DATABASE_URL")
    if raw_url is None:
        pytest.skip("Set TEST_DATABASE_URL to run integration tests")
    return to_sqlalchemy_url(raw_url)


async def _truncate(engine) -> None:
    """Truncate all entry/meal/memory-related tables, restarting identity sequences.

    **Inputs:**
    - engine: SQLAlchemy async engine bound to the integration database.
    """
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
    """Session-scoped async session factory bound to the integration engine.

    **Outputs:**
    - ``async_sessionmaker[AsyncSession]``: factory yielding async sessions.
    """
    engine = create_async_engine(_integration_database_url(), pool_pre_ping=True)
    factory: async_sessionmaker[AsyncSession] = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()


@pytest_asyncio.fixture(autouse=True)
async def clean_database(session_factory: async_sessionmaker[AsyncSession]) -> None:
    """Auto-applied fixture that truncates suite tables before and after each test.

    **Inputs:**
    - session_factory: session-scoped factory whose bound engine drives truncation.
    """
    await _truncate(session_factory.kw["bind"])
    yield
    await _truncate(session_factory.kw["bind"])


@pytest_asyncio.fixture
async def session(session_factory: async_sessionmaker[AsyncSession]) -> AsyncSession:
    """Per-test async session opened from the shared factory.

    **Inputs:**
    - session_factory: shared ``async_sessionmaker`` fixture.

    **Outputs:**
    - ``AsyncSession``: open session, closed when the test completes.
    """
    async with session_factory() as db_session:
        yield db_session


@pytest.mark.asyncio
async def test_save_custom_food_writes_memory_pointer(session: AsyncSession) -> None:
    """``upsert_custom_food_and_remember`` writes a ``food_memory`` row that ``resolve_food_by_name`` returns as ``custom_food``."""
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
    """``resolve_food_by_name`` returns a ``type='none'`` result when no memory exists for the name."""
    user_key = f"user-{uuid.uuid4()}"
    resolved = await resolve_food_by_name(session=session, user_key=user_key, name="missing")
    assert resolved.type == "none"


@pytest.mark.asyncio
async def test_food_memory_usda_round_trip(session: AsyncSession) -> None:
    """A USDA-backed ``food_memory`` row written via ``upsert_usda`` resolves via ``resolve_food_by_name`` with macros intact and case-insensitive name match."""
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
    """``food_entries`` CHECK rejects a row that carries both ``usda_fdc_id`` and ``custom_food_id``."""
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
    """``log_meal`` expands every meal item into a ``food_entries`` row stamped with the meal id and name and shared ``entry_group_id``."""
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

    # New: meal link is stamped on every created row.
    assert all(r["meal_id"] == meal_row["id"] for r in created_rows)
    assert all(r["meal_name"] == "My Breakfast" for r in created_rows)


@pytest.mark.asyncio
async def test_delete_custom_food_blocked_when_referenced(session: AsyncSession) -> None:
    """Deleting a ``custom_foods`` row that is still referenced by a ``food_entries`` row fails with ``IntegrityError``."""
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
async def test_entries_reject_unowned_custom_food_id(session: AsyncSession) -> None:
    """``create_entries_with_side_effects`` refuses a ``custom_food_id`` owned by another user."""
    from fastapi import HTTPException

    from pulse_server.models import FoodEntryCreate
    from pulse_server.services.custom_foods_service import CrossTenantReferenceError
    from pulse_server.services.entries_service import create_entries_with_side_effects

    owner = f"user-{uuid.uuid4()}"
    attacker = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)

    async with transaction(session):
        cf = await CustomFoodsRepository(session).create(
            user_key=owner,
            name="Owner CF",
            normalized_name="owner cf",
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

    item = FoodEntryCreate(
        display_name="stolen",
        quantity_text="1",
        custom_food_id=cf["id"],
        calories=100,
        protein_g=5,
        carbs_g=10,
        fat_g=2,
    )
    with pytest.raises((CrossTenantReferenceError, HTTPException)):
        await create_entries_with_side_effects(
            session=session, user_key=attacker, items=[item], now=now
        )


@pytest.mark.asyncio
async def test_entries_allow_owned_custom_food_id(session: AsyncSession) -> None:
    """The owner can log an entry that references their own custom food."""
    from pulse_server.models import FoodEntryCreate
    from pulse_server.services.entries_service import create_entries_with_side_effects

    owner = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)

    async with transaction(session):
        cf = await CustomFoodsRepository(session).create(
            user_key=owner,
            name="Owner CF",
            normalized_name="owner cf",
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

    item = FoodEntryCreate(
        display_name="mine",
        quantity_text="1",
        custom_food_id=cf["id"],
        calories=100,
        protein_g=5,
        carbs_g=10,
        fat_g=2,
    )
    created_rows, _ = await create_entries_with_side_effects(
        session=session, user_key=owner, items=[item], now=now
    )
    assert created_rows[0]["custom_food_id"] == cf["id"]


@pytest.mark.asyncio
async def test_meal_create_rejects_unowned_custom_food_id(session: AsyncSession) -> None:
    """``create_meal_with_items`` rejects an item referencing another user's custom food (422)."""
    from fastapi import HTTPException

    owner = f"user-{uuid.uuid4()}"
    attacker = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)

    async with transaction(session):
        cf = await CustomFoodsRepository(session).create(
            user_key=owner,
            name="Owner CF",
            normalized_name="owner cf",
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

    payload = MealCreate(
        name="Stolen Meal",
        items=[
            MealItemCreate(
                display_name="stolen item",
                quantity_text="1",
                custom_food_id=cf["id"],
                calories=100,
                protein_g=5,
                carbs_g=10,
                fat_g=2,
            )
        ],
    )
    with pytest.raises(HTTPException) as exc_info:
        async with transaction(session):
            await create_meal_with_items(
                session=session, user_key=attacker, payload=payload, now=now
            )
    assert exc_info.value.status_code == 422


@pytest.mark.asyncio
async def test_meal_unique_name_per_user(session: AsyncSession) -> None:
    """``create_meal_with_items`` enforces unique normalized meal names per user."""
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
    """``MealsRepository.list_meals`` returns per-meal ``item_count`` and macro totals (including zero for empty meals)."""
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
    combo = MealCreate(
        name="Combo",
        items=[
            MealItemCreate(
                display_name="a",
                quantity_text="1",
                usda_fdc_id=1,
                usda_description="x",
                calories=200,
                protein_g=10,
                carbs_g=20,
                fat_g=4,
            ),
            MealItemCreate(
                display_name="b",
                quantity_text="1",
                usda_fdc_id=2,
                usda_description="y",
                calories=50,
                protein_g=2.5,
                carbs_g=5,
                fat_g=1.5,
            ),
        ],
    )
    async with transaction(session):
        await create_meal_with_items(session=session, user_key=user_key, payload=payload, now=now)
        await create_meal_with_items(session=session, user_key=user_key, payload=combo, now=now)
        await repo.create_meal(
            user_key=user_key, name="Empty", normalized_name="empty", notes=None, now=now
        )

    rows = await repo.list_meals(user_key)
    by_name = {row["normalized_name"]: row for row in rows}
    assert int(by_name["snack"]["item_count"]) == 1
    assert int(by_name["empty"]["item_count"]) == 0
    assert int(by_name["combo"]["item_count"]) == 2

    assert int(by_name["snack"]["total_calories"]) == 100
    assert float(by_name["snack"]["total_protein_g"]) == pytest.approx(5.0)
    assert float(by_name["snack"]["total_carbs_g"]) == pytest.approx(10.0)
    assert float(by_name["snack"]["total_fat_g"]) == pytest.approx(3.0)

    assert int(by_name["combo"]["total_calories"]) == 250
    assert float(by_name["combo"]["total_protein_g"]) == pytest.approx(12.5)
    assert float(by_name["combo"]["total_carbs_g"]) == pytest.approx(25.0)
    assert float(by_name["combo"]["total_fat_g"]) == pytest.approx(5.5)

    assert int(by_name["empty"]["total_calories"]) == 0
    assert float(by_name["empty"]["total_protein_g"]) == pytest.approx(0.0)
    assert float(by_name["empty"]["total_carbs_g"]) == pytest.approx(0.0)
    assert float(by_name["empty"]["total_fat_g"]) == pytest.approx(0.0)


@pytest.mark.asyncio
async def test_manual_entry_has_null_meal_link(session: AsyncSession) -> None:
    """Ad-hoc ``create_food_entry`` calls store NULL ``meal_id`` and ``meal_name``."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    log_date = now.date()
    entries_repo = EntriesRepository(session)

    async with transaction(session):
        log_id = entries_repo.daily_log_id(user_key=user_key, log_date=log_date)
        await entries_repo.ensure_daily_log(log_id, user_key, log_date)
        row = await entries_repo.create_food_entry(
            entry_id=uuid.uuid4(),
            daily_log_id=log_id,
            user_key=user_key,
            entry_group_id=uuid.uuid4(),
            display_name="ad-hoc",
            quantity_text="1",
            normalized_quantity_value=None,
            normalized_quantity_unit=None,
            usda_fdc_id=200003,
            usda_description="ad-hoc usda",
            custom_food_id=None,
            calories=50,
            protein_g=1,
            carbs_g=10,
            fat_g=2,
            consumed_at=now,
        )

    assert row["meal_id"] is None
    assert row["meal_name"] is None


@pytest.mark.asyncio
async def test_meal_rename_does_not_mutate_historical_entries(session: AsyncSession) -> None:
    """Renaming a meal leaves the stamped ``meal_name`` on already-logged ``food_entries`` rows unchanged."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)

    payload = MealCreate(
        name="Original Name",
        notes=None,
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
        ],
    )
    async with transaction(session):
        meal_row, _ = await create_meal_with_items(
            session=session, user_key=user_key, payload=payload, now=now
        )

    created_rows, _ = await log_meal(
        session=session, user_key=user_key, meal_id=meal_row["id"], now=now
    )
    assert created_rows[0]["meal_name"] == "Original Name"

    # Rename the meal (direct UPDATE — covers the "what if a write happens later" case).
    from sqlalchemy import update as sa_update
    from pulse_server.repositories.tables import meals as meals_table

    async with transaction(session):
        await session.execute(
            sa_update(meals_table)
            .where(meals_table.c.id == meal_row["id"])
            .values(name="Renamed", normalized_name="renamed")
        )

    # Re-read the entry; its meal_name must still read "Original Name".
    entries_repo = EntriesRepository(session)
    log_id = entries_repo.daily_log_id(user_key=user_key, log_date=now.date())
    rows = await entries_repo.list_entries_by_daily_log_id(log_id)
    assert rows[0]["meal_id"] == meal_row["id"]
    assert rows[0]["meal_name"] == "Original Name"


@pytest.mark.asyncio
async def test_meal_delete_sets_meal_id_null_keeps_meal_name(session: AsyncSession) -> None:
    """Deleting a meal nulls ``meal_id`` on its historical entries while preserving the stamped ``meal_name``."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)

    payload = MealCreate(
        name="Doomed Meal",
        notes=None,
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
        ],
    )
    async with transaction(session):
        meal_row, _ = await create_meal_with_items(
            session=session, user_key=user_key, payload=payload, now=now
        )

    await log_meal(
        session=session, user_key=user_key, meal_id=meal_row["id"], now=now
    )

    # Delete the meal directly through the repo.
    repo = MealsRepository(session)
    async with transaction(session):
        deleted = await repo.delete_meal(meal_row["id"], user_key)
    assert deleted is True

    entries_repo = EntriesRepository(session)
    log_id = entries_repo.daily_log_id(user_key=user_key, log_date=now.date())
    rows = await entries_repo.list_entries_by_daily_log_id(log_id)
    assert rows[0]["meal_id"] is None
    assert rows[0]["meal_name"] == "Doomed Meal"


@pytest.mark.asyncio
async def test_public_entries_path_ignores_client_supplied_meal_link(session: AsyncSession) -> None:
    """``create_entries_with_side_effects`` drops client-supplied ``meal_id``/``meal_name`` fields rather than stamping them on the row."""
    from pulse_server.models import FoodEntryCreate
    from pulse_server.services.entries_service import create_entries_with_side_effects

    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)

    # Simulate the request payload — extra meal_id / meal_name keys included by a malicious
    # or buggy client. model_validate accepts and silently drops unknown fields.
    item = FoodEntryCreate.model_validate({
        "display_name": "ad-hoc",
        "quantity_text": "1",
        "usda_fdc_id": 200099,
        "usda_description": "ad-hoc",
        "calories": 50,
        "protein_g": 1,
        "carbs_g": 10,
        "fat_g": 2,
        "consumed_at": now,
        "meal_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "meal_name": "Forged Meal",
    })

    created_rows, _ = await create_entries_with_side_effects(
        session=session, user_key=user_key, items=[item], now=now
    )
    assert len(created_rows) == 1
    assert created_rows[0]["meal_id"] is None
    assert created_rows[0]["meal_name"] is None
