"""Integration tests for entries + logs + summary repositories.

Covers two scenarios end-to-end against Postgres: transactional rollback of
``create_entries_with_side_effects`` when a duplicate ``entry_id`` triggers a PK
violation mid-batch (no partial rows persist), and the per-day aggregate /
remaining-target math served by ``LogsRepository.list_logs`` plus
``build_daily_summary`` over multiple ``food_entries`` rows. Integration test:
hits a real Postgres via ``TEST_DATABASE_URL``.
"""

from __future__ import annotations

import os
import uuid
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from datetime import timezone as TimezoneValue
from unittest.mock import patch

import pytest
import pytest_asyncio
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from pulse_server.db import to_sqlalchemy_url, transaction
from pulse_server.models import FoodEntryCreate
from pulse_server.repositories.entries import EntriesRepository
from pulse_server.repositories.logs import LogsRepository
from pulse_server.repositories.targets import TargetsRepository
from pulse_server.services.entries_service import create_entries_with_side_effects
from pulse_server.services.summary_service import build_daily_summary

pytestmark = pytest.mark.integration


def _integration_database_url() -> str:
    """Return the integration database URL from test environment variables.

    **Outputs:**
    - str: SQLAlchemy-compatible async database URL for integration tests.

    **Exceptions:**
    - ``pytest.skip.Exception``: Raised when no integration database URL is configured.
    """
    raw_url = os.getenv("TEST_DATABASE_URL")
    if raw_url is None:
        pytest.skip("Set TEST_DATABASE_URL to run integration tests")
    return to_sqlalchemy_url(raw_url)


async def _truncate_tables(engine) -> None:
    """Truncate integration test tables so each test starts from clean state.

    **Inputs:**
    - engine (``sqlalchemy.ext.asyncio.AsyncEngine``): async SQLAlchemy engine for the test database.

    **Exceptions:**
    - ``sqlalchemy.exc.SQLAlchemyError``: Raised when truncation SQL execution fails.
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
    """Build a reusable async session factory for integration test cases.

    **Outputs:**
    - ``async_sessionmaker[AsyncSession]``: factory that creates independent async sessions.
    """
    engine = create_async_engine(_integration_database_url(), pool_pre_ping=True)
    factory: async_sessionmaker[AsyncSession] = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()


@pytest_asyncio.fixture(autouse=True)
async def clean_database(session_factory: async_sessionmaker[AsyncSession]) -> None:
    """Clear integration test tables before and after each test function.

    **Inputs:**
    - session_factory (``async_sessionmaker[AsyncSession]``): session factory fixture with bound engine.
    """
    await _truncate_tables(session_factory.kw["bind"])
    yield
    await _truncate_tables(session_factory.kw["bind"])


@pytest_asyncio.fixture
async def session(session_factory: async_sessionmaker[AsyncSession]) -> AsyncSession:
    """Create a per-test async session for repository/service integration checks.

    **Inputs:**
    - session_factory (``async_sessionmaker[AsyncSession]``): fixture-provided async session factory.

    **Outputs:**
    - ``AsyncSession``: open SQLAlchemy async session with explicit lifecycle management.
    """
    async with session_factory() as db_session:
        yield db_session


@pytest.mark.asyncio
async def test_create_entries_rolls_back_on_error(session: AsyncSession) -> None:
    """``create_entries_with_side_effects`` rolls back the full batch when a duplicate ``entry_id`` triggers an ``IntegrityError`` mid-transaction."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    log_date = now.date()

    item = FoodEntryCreate(
        display_name="eggs",
        quantity_text="2 eggs",
        usda_fdc_id=171287,
        usda_description="Egg, whole, raw",
        calories=140,
        protein_g=12.0,
        carbs_g=1.0,
        fat_g=10.0,
        date=log_date,
        consumed_at=now,
    )

    duplicate_entry_id = uuid.uuid4()
    batch_entry_group_id = uuid.uuid4()
    # create_entries_with_side_effects calls uuid4 once for the batch entry_group_id, then once
    # per item for entry_id. Duplicate entry_id on the second item forces PK violation.
    uuid_side_effect = [
        batch_entry_group_id,
        duplicate_entry_id,
        duplicate_entry_id,
    ]

    with patch("pulse_server.services.entries_service.uuid.uuid4", side_effect=uuid_side_effect):
        with pytest.raises(IntegrityError):
            await create_entries_with_side_effects(
                session=session,
                user_key=user_key,
                items=[item, item],
                now=now,
            )

    entries_repo = EntriesRepository(session)
    daily_log_id = entries_repo.daily_log_id(user_key=user_key, log_date=log_date)
    persisted_rows = await entries_repo.list_entries_by_daily_log_id(daily_log_id=daily_log_id)
    assert persisted_rows == []


@pytest.mark.asyncio
async def test_logs_and_summary_aggregates(session: AsyncSession) -> None:
    """``LogsRepository.list_logs`` and ``build_daily_summary`` aggregate per-day macros and compute remaining targets correctly."""
    user_key = f"user-{uuid.uuid4()}"
    target_repo = TargetsRepository(session)
    logs_repo = LogsRepository(session)
    entries_repo = EntriesRepository(session)

    first_date = DateValue(2026, 4, 5)
    second_date = DateValue(2026, 4, 6)
    consumed_at = DateTimeValue(2026, 4, 6, 12, 0, tzinfo=TimezoneValue.utc)

    async with transaction(session):
        await target_repo.upsert_targets(
            user_key=user_key,
            calories=2000,
            protein_g=150.0,
            carbs_g=200.0,
            fat_g=70.0,
            updated_at=consumed_at,
        )

        first_log_id = entries_repo.daily_log_id(user_key=user_key, log_date=first_date)
        second_log_id = entries_repo.daily_log_id(user_key=user_key, log_date=second_date)

        await entries_repo.ensure_daily_log(first_log_id, user_key, first_date)
        await entries_repo.ensure_daily_log(second_log_id, user_key, second_date)

        await entries_repo.create_food_entry(
            entry_id=uuid.uuid4(),
            daily_log_id=first_log_id,
            user_key=user_key,
            entry_group_id=uuid.uuid4(),
            display_name="oats",
            quantity_text="1 bowl",
            normalized_quantity_value=1,
            normalized_quantity_unit="bowl",
            usda_fdc_id=200001,
            usda_description="Oats",
            custom_food_id=None,
            calories=300,
            protein_g=10,
            carbs_g=50,
            fat_g=5,
            consumed_at=consumed_at,
        )
        await entries_repo.create_food_entry(
            entry_id=uuid.uuid4(),
            daily_log_id=first_log_id,
            user_key=user_key,
            entry_group_id=uuid.uuid4(),
            display_name="milk",
            quantity_text="1 cup",
            normalized_quantity_value=1,
            normalized_quantity_unit="cup",
            usda_fdc_id=200002,
            usda_description="Milk",
            custom_food_id=None,
            calories=100,
            protein_g=8,
            carbs_g=12,
            fat_g=3,
            consumed_at=consumed_at,
        )
        await entries_repo.create_food_entry(
            entry_id=uuid.uuid4(),
            daily_log_id=second_log_id,
            user_key=user_key,
            entry_group_id=uuid.uuid4(),
            display_name="banana",
            quantity_text="1 banana",
            normalized_quantity_value=1,
            normalized_quantity_unit="item",
            usda_fdc_id=200003,
            usda_description="Banana",
            custom_food_id=None,
            calories=120,
            protein_g=1,
            carbs_g=31,
            fat_g=0,
            consumed_at=consumed_at,
        )

    log_rows = await logs_repo.list_logs(user_key=user_key, from_date=first_date, to_date=second_date)
    assert len(log_rows) == 2
    rows_by_date = {row["log_date"]: row for row in log_rows}
    assert int(rows_by_date[first_date]["total_calories"]) == 400
    assert float(rows_by_date[first_date]["total_protein_g"]) == 18.0
    assert int(rows_by_date[second_date]["total_calories"]) == 120
    assert float(rows_by_date[second_date]["total_protein_g"]) == 1.0

    summary = await build_daily_summary(session=session, user_key=user_key, summary_date=first_date)
    assert summary.consumed.calories == 400
    assert summary.consumed.protein_g == 18.0
    assert summary.remaining.calories == 1600
    assert summary.remaining.carbs_g == 138.0
