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
from datetime import UTC
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from unittest.mock import patch

import pytest
import pytest_asyncio
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from pulse_server.db import to_sqlalchemy_url, transaction
from pulse_server.models import FoodEntryCreate
from pulse_server.log_ids import daily_log_id as canonical_daily_log_id
from pulse_server.repositories.entries import EntriesRepository, FoodEntryPayload
from pulse_server.repositories.logs import LogsRepository
from pulse_server.repositories.targets import TargetsRepository
from pulse_server.services.entries_service import (
    confirm_pending_entries,
    create_entries_with_side_effects,
    unconfirm_entries,
)
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
    now = DateTimeValue.now(tz=UTC)
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
    consumed_at = DateTimeValue(2026, 4, 6, 12, 0, tzinfo=UTC)

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
            FoodEntryPayload(
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
        )
        await entries_repo.create_food_entry(
            FoodEntryPayload(
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
        )
        await entries_repo.create_food_entry(
            FoodEntryPayload(
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
        )

    log_rows = await logs_repo.list_logs(
        user_key=user_key, from_date=first_date, to_date=second_date
    )
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


def _payload(
    *,
    daily_log_id: str,
    user_key: str,
    calories: int,
    consumed_at: DateTimeValue,
    confirmed: bool = True,
    fdc_id: int = 900001,
    name: str = "food",
) -> FoodEntryPayload:
    """Build a minimal USDA-backed ``FoodEntryPayload`` for pending-flag tests.

    **Inputs:**
    - daily_log_id (str): Owning daily-log id.
    - user_key (str): Owning user key.
    - calories (int): Calories to record (protein/carbs/fat fixed at 1.0).
    - consumed_at (DateTimeValue): Consumption timestamp.
    - confirmed (bool): Whether the entry counts toward totals (default ``True``).
    - fdc_id (int): USDA id to satisfy the one-source constraint.
    - name (str): Display name for the entry.

    **Outputs:**
    - FoodEntryPayload: Frozen payload ready for ``create_food_entry``.
    """
    return FoodEntryPayload(
        entry_id=uuid.uuid4(),
        daily_log_id=daily_log_id,
        user_key=user_key,
        entry_group_id=uuid.uuid4(),
        display_name=name,
        quantity_text="1 serving",
        normalized_quantity_value=1,
        normalized_quantity_unit="serving",
        usda_fdc_id=fdc_id,
        usda_description=name,
        custom_food_id=None,
        calories=calories,
        protein_g=1,
        carbs_g=1,
        fat_g=1,
        consumed_at=consumed_at,
        confirmed=confirmed,
    )


@pytest.mark.asyncio
async def test_create_food_entry_persists_confirmed_flag(session: AsyncSession) -> None:
    """``create_food_entry`` stores ``confirmed`` (default true, explicit false) and lists it back."""
    user_key = f"user-{uuid.uuid4()}"
    log_date = DateValue(2026, 5, 1)
    consumed_at = DateTimeValue(2026, 5, 1, 12, 0, tzinfo=UTC)
    entries_repo = EntriesRepository(session)
    log_id = entries_repo.daily_log_id(user_key=user_key, log_date=log_date)

    async with transaction(session):
        await entries_repo.ensure_daily_log(log_id, user_key, log_date)
        await entries_repo.create_food_entry(
            _payload(daily_log_id=log_id, user_key=user_key, calories=200, consumed_at=consumed_at)
        )
        await entries_repo.create_food_entry(
            _payload(
                daily_log_id=log_id,
                user_key=user_key,
                calories=700,
                consumed_at=consumed_at,
                confirmed=False,
            )
        )

    rows = await entries_repo.list_entries_by_daily_log_id(log_id)
    by_cal = {row["calories"]: row["confirmed"] for row in rows}
    assert by_cal == {200: True, 700: False}


@pytest.mark.asyncio
async def test_list_logs_excludes_unconfirmed(session: AsyncSession) -> None:
    """``list_logs`` sums/counts only confirmed entries; a pending-only day appears with zeros."""
    user_key = f"user-{uuid.uuid4()}"
    mixed_date = DateValue(2026, 5, 2)
    pending_only_date = DateValue(2026, 5, 3)
    consumed_at = DateTimeValue(2026, 5, 2, 12, 0, tzinfo=UTC)
    entries_repo = EntriesRepository(session)
    logs_repo = LogsRepository(session)
    mixed_log = entries_repo.daily_log_id(user_key=user_key, log_date=mixed_date)
    pending_log = entries_repo.daily_log_id(user_key=user_key, log_date=pending_only_date)

    async with transaction(session):
        await entries_repo.ensure_daily_log(mixed_log, user_key, mixed_date)
        await entries_repo.ensure_daily_log(pending_log, user_key, pending_only_date)
        await entries_repo.create_food_entry(
            _payload(
                daily_log_id=mixed_log, user_key=user_key, calories=300, consumed_at=consumed_at
            )
        )
        await entries_repo.create_food_entry(
            _payload(
                daily_log_id=mixed_log,
                user_key=user_key,
                calories=999,
                consumed_at=consumed_at,
                confirmed=False,
            )
        )
        await entries_repo.create_food_entry(
            _payload(
                daily_log_id=pending_log,
                user_key=user_key,
                calories=800,
                consumed_at=consumed_at,
                confirmed=False,
            )
        )

    rows = await logs_repo.list_logs(
        user_key=user_key, from_date=mixed_date, to_date=pending_only_date
    )
    by_date = {row["log_date"]: row for row in rows}
    assert int(by_date[mixed_date]["total_calories"]) == 300
    assert int(by_date[mixed_date]["entry_count"]) == 1
    # The pending-only day still appears (outer join) but contributes nothing.
    assert int(by_date[pending_only_date]["total_calories"]) == 0
    assert int(by_date[pending_only_date]["entry_count"]) == 0


@pytest.mark.asyncio
async def test_calorie_totals_by_day_excludes_unconfirmed(session: AsyncSession) -> None:
    """``calorie_totals_by_day`` sums only confirmed entries."""
    user_key = f"user-{uuid.uuid4()}"
    log_date = DateValue(2026, 5, 4)
    consumed_at = DateTimeValue(2026, 5, 4, 12, 0, tzinfo=UTC)
    entries_repo = EntriesRepository(session)
    log_id = entries_repo.daily_log_id(user_key=user_key, log_date=log_date)

    async with transaction(session):
        await entries_repo.ensure_daily_log(log_id, user_key, log_date)
        await entries_repo.create_food_entry(
            _payload(daily_log_id=log_id, user_key=user_key, calories=300, consumed_at=consumed_at)
        )
        await entries_repo.create_food_entry(
            _payload(
                daily_log_id=log_id,
                user_key=user_key,
                calories=999,
                consumed_at=consumed_at,
                confirmed=False,
            )
        )

    rows = await entries_repo.calorie_totals_by_day(
        user_key=user_key, from_date=log_date, to_date=log_date
    )
    assert [(row["log_date"], int(row["calories"])) for row in rows] == [(log_date, 300)]


@pytest.mark.asyncio
async def test_confirm_entries_flips_scoped_and_idempotent(session: AsyncSession) -> None:
    """``confirm_entries`` flips pending→confirmed, is user-scoped, and is idempotent."""
    user_key = f"user-{uuid.uuid4()}"
    other_user = f"user-{uuid.uuid4()}"
    log_date = DateValue(2026, 5, 5)
    consumed_at = DateTimeValue(2026, 5, 5, 12, 0, tzinfo=UTC)
    entries_repo = EntriesRepository(session)
    log_id = entries_repo.daily_log_id(user_key=user_key, log_date=log_date)

    async with transaction(session):
        await entries_repo.ensure_daily_log(log_id, user_key, log_date)
        pending_row = await entries_repo.create_food_entry(
            _payload(
                daily_log_id=log_id,
                user_key=user_key,
                calories=500,
                consumed_at=consumed_at,
                confirmed=False,
            )
        )
    entry_id = pending_row["id"]

    # Wrong user confirms nothing.
    async with transaction(session):
        none_confirmed = await entries_repo.confirm_entries([entry_id], other_user)
    assert none_confirmed == []

    # Owner confirms the entry.
    async with transaction(session):
        confirmed = await entries_repo.confirm_entries([entry_id], user_key)
    assert len(confirmed) == 1
    assert confirmed[0]["id"] == entry_id
    assert confirmed[0]["confirmed"] is True

    # Re-confirming is a no-op (already confirmed → no rows updated).
    async with transaction(session):
        again = await entries_repo.confirm_entries([entry_id], user_key)
    assert again == []

    rows = await entries_repo.list_entries_by_daily_log_id(log_id)
    assert rows[0]["confirmed"] is True


@pytest.mark.asyncio
async def test_unconfirm_entries_flips_scoped_and_idempotent(session: AsyncSession) -> None:
    """``unconfirm_entries`` flips confirmed→pending, is user-scoped, and is idempotent."""
    user_key = "khash"
    other_user = "intruder"
    entries_repo = EntriesRepository(session)
    log_date = DateValue(2026, 6, 22)
    log_id = canonical_daily_log_id(user_key, log_date)
    await entries_repo.ensure_daily_log(log_id, user_key, log_date)
    entry_id = uuid.uuid4()
    await entries_repo.create_food_entry(
        FoodEntryPayload(
            entry_id=entry_id, daily_log_id=log_id, user_key=user_key,
            entry_group_id=uuid.uuid4(), display_name="Bowl", quantity_text="1",
            normalized_quantity_value=None, normalized_quantity_unit=None,
            usda_fdc_id=1, usda_description="Bowl", custom_food_id=None,
            calories=600, protein_g=50, carbs_g=40, fat_g=20,
            consumed_at=DateTimeValue(2026, 6, 22, 12, 0), meal_id=None,
            meal_name=None, confirmed=True,
        )
    )

    # Another user cannot unconfirm it.
    assert await entries_repo.unconfirm_entries([entry_id], other_user) == []

    changed = await entries_repo.unconfirm_entries([entry_id], user_key)
    assert len(changed) == 1
    assert changed[0]["confirmed"] is False

    # Idempotent: already-pending rows are skipped.
    assert await entries_repo.unconfirm_entries([entry_id], user_key) == []


@pytest.mark.asyncio
async def test_daily_summary_consumed_excludes_pending_but_lists_it(session: AsyncSession) -> None:
    """``build_daily_summary`` excludes pending from ``consumed`` yet still returns the pending entry flagged."""
    user_key = f"user-{uuid.uuid4()}"
    log_date = DateValue(2026, 5, 6)
    consumed_at = DateTimeValue(2026, 5, 6, 12, 0, tzinfo=UTC)
    entries_repo = EntriesRepository(session)
    log_id = entries_repo.daily_log_id(user_key=user_key, log_date=log_date)

    async with transaction(session):
        await entries_repo.ensure_daily_log(log_id, user_key, log_date)
        await entries_repo.create_food_entry(
            _payload(daily_log_id=log_id, user_key=user_key, calories=300, consumed_at=consumed_at)
        )
        await entries_repo.create_food_entry(
            _payload(
                daily_log_id=log_id,
                user_key=user_key,
                calories=700,
                consumed_at=consumed_at,
                confirmed=False,
            )
        )

    summary = await build_daily_summary(
        session=session, user_key=user_key, summary_date=log_date, missing_target="null"
    )
    assert summary.consumed.calories == 300
    assert len(summary.entries) == 2
    assert sorted(entry.confirmed for entry in summary.entries) == [False, True]


@pytest.mark.asyncio
async def test_confirm_pending_entries_rejects_cross_day(session: AsyncSession) -> None:
    """``confirm_pending_entries`` raises (and rolls back) when ids span two days."""
    user_key = f"user-{uuid.uuid4()}"
    day_a = DateValue(2026, 5, 7)
    day_b = DateValue(2026, 5, 8)
    entries_repo = EntriesRepository(session)
    log_a = entries_repo.daily_log_id(user_key=user_key, log_date=day_a)
    log_b = entries_repo.daily_log_id(user_key=user_key, log_date=day_b)

    async with transaction(session):
        await entries_repo.ensure_daily_log(log_a, user_key, day_a)
        await entries_repo.ensure_daily_log(log_b, user_key, day_b)
        row_a = await entries_repo.create_food_entry(
            _payload(
                daily_log_id=log_a,
                user_key=user_key,
                calories=300,
                consumed_at=DateTimeValue(2026, 5, 7, 12, 0, tzinfo=UTC),
                confirmed=False,
            )
        )
        row_b = await entries_repo.create_food_entry(
            _payload(
                daily_log_id=log_b,
                user_key=user_key,
                calories=400,
                consumed_at=DateTimeValue(2026, 5, 8, 12, 0, tzinfo=UTC),
                confirmed=False,
            )
        )

    with pytest.raises(ValueError, match="same day"):
        await confirm_pending_entries(session, user_key, [row_a["id"], row_b["id"]])

    # The cross-day confirm rolled back: both entries are still pending.
    rows_a = await entries_repo.list_entries_by_daily_log_id(log_a)
    rows_b = await entries_repo.list_entries_by_daily_log_id(log_b)
    assert rows_a[0]["confirmed"] is False
    assert rows_b[0]["confirmed"] is False


@pytest.mark.asyncio
@pytest.mark.integration
async def test_unconfirm_entries_rejects_cross_day(session: AsyncSession) -> None:
    """``unconfirm_entries`` rejects ids spanning more than one day."""
    user_key = f"user-{uuid.uuid4()}"
    entries_repo = EntriesRepository(session)
    ids: list[uuid.UUID] = []
    async with transaction(session):
        for day in (DateValue(2026, 6, 21), DateValue(2026, 6, 22)):
            log_id = canonical_daily_log_id(user_key, day)
            await entries_repo.ensure_daily_log(log_id, user_key, day)
            entry_id = uuid.uuid4()
            ids.append(entry_id)
            await entries_repo.create_food_entry(
                FoodEntryPayload(
                    entry_id=entry_id, daily_log_id=log_id, user_key=user_key,
                    entry_group_id=uuid.uuid4(), display_name="Bowl", quantity_text="1",
                    normalized_quantity_value=None, normalized_quantity_unit=None,
                    usda_fdc_id=1, usda_description="Bowl", custom_food_id=None,
                    calories=100, protein_g=1, carbs_g=1, fat_g=1,
                    consumed_at=DateTimeValue(day.year, day.month, day.day, 12, 0),
                    meal_id=None, meal_name=None, confirmed=True,
                )
            )

    with pytest.raises(ValueError):
        await unconfirm_entries(session=session, user_key=user_key, entry_ids=ids)


@pytest.mark.asyncio
@pytest.mark.integration
async def test_unconfirm_entries_returns_changed_and_day_rows(session: AsyncSession) -> None:
    """``unconfirm_entries`` returns the changed rows plus the day's full rows."""
    user_key = f"user-{uuid.uuid4()}"
    entries_repo = EntriesRepository(session)
    day = DateValue(2026, 6, 22)
    log_id = canonical_daily_log_id(user_key, day)
    keep_id, flip_id = uuid.uuid4(), uuid.uuid4()
    async with transaction(session):
        await entries_repo.ensure_daily_log(log_id, user_key, day)
        for entry_id, kcal in ((keep_id, 300), (flip_id, 700)):
            await entries_repo.create_food_entry(
                FoodEntryPayload(
                    entry_id=entry_id, daily_log_id=log_id, user_key=user_key,
                    entry_group_id=uuid.uuid4(), display_name="Bowl", quantity_text="1",
                    normalized_quantity_value=None, normalized_quantity_unit=None,
                    usda_fdc_id=1, usda_description="Bowl", custom_food_id=None,
                    calories=kcal, protein_g=1, carbs_g=1, fat_g=1,
                    consumed_at=DateTimeValue(2026, 6, 22, 12, 0),
                    meal_id=None, meal_name=None, confirmed=True,
                )
            )

    changed, day_rows = await unconfirm_entries(
        session=session, user_key=user_key, entry_ids=[flip_id]
    )
    assert len(changed) == 1 and changed[0]["id"] == flip_id
    assert len(day_rows) == 2
