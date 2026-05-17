"""Integration tests for the weight-entry service + repository stack.

Covers ``upsert_weight`` (kg→lb conversion, same-day replacement keeping the row
id), ``get_weight`` round-trip, ``list_weight_range`` ordering, ``delete_weight``
return semantics (True then False on a repeat), and idempotency of
``bootstrap_schema``. Integration test: hits a real Postgres via
``TEST_DATABASE_URL`` through the module-level ``db`` pool.
"""

from __future__ import annotations

import os
import uuid
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from datetime import timedelta as TimeDeltaValue
from datetime import timezone as TimezoneValue
from decimal import Decimal

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server import db
from diet_tracker_server.repositories.weight import WeightRepository
from diet_tracker_server.services.weight_service import (
    delete_weight,
    get_weight,
    list_weight_range,
    upsert_weight,
)


pytestmark = pytest.mark.integration


@pytest_asyncio.fixture
async def session() -> AsyncSession:
    """Initialize the module DB pool, run schema bootstrap, truncate weight rows, and yield a session.

    **Outputs:**
    - ``AsyncSession``: open async session over the integration database.
    """
    test_db_url = os.environ.get("TEST_DATABASE_URL")
    if test_db_url is None:
        pytest.skip("Set TEST_DATABASE_URL to run integration tests")
    await db.init_pool(test_db_url)
    await db.bootstrap_schema()
    async with db.get_session() as s:
        await s.execute(text("truncate table weight_entries"))
        await s.commit()
        yield s
    await db.close_pool()


@pytest.mark.asyncio
async def test_upsert_then_get(session: AsyncSession) -> None:
    """``upsert_weight`` converts kg→lb (70kg→154.32lb) and ``get_weight`` returns the stored value."""
    today = DateValue.today()
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    user_key = "test_user_" + uuid.uuid4().hex[:8]

    upserted = await upsert_weight(
        session=session,
        user_key=user_key,
        log_date=today,
        weight=Decimal("70"),
        unit="kg",
        now=now,
    )
    assert upserted.weight_lb == Decimal("154.32")
    assert upserted.source_unit == "kg"

    fetched = await get_weight(session=session, user_key=user_key, log_date=today)
    assert fetched is not None
    assert fetched.weight_lb == Decimal("154.32")


@pytest.mark.asyncio
async def test_upsert_replaces_same_date(session: AsyncSession) -> None:
    """A second ``upsert_weight`` on the same date updates the row in place, preserving its id."""
    today = DateValue.today()
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    user_key = "test_user_" + uuid.uuid4().hex[:8]

    first = await upsert_weight(
        session=session, user_key=user_key, log_date=today,
        weight=Decimal("180"), unit="lb", now=now,
    )
    second = await upsert_weight(
        session=session, user_key=user_key, log_date=today,
        weight=Decimal("181.5"), unit="lb",
        now=now + TimeDeltaValue(seconds=1),
    )
    assert second.id == first.id
    assert second.weight_lb == Decimal("181.50")


@pytest.mark.asyncio
async def test_list_range(session: AsyncSession) -> None:
    """``list_weight_range`` returns all entries in the inclusive window ordered by ``log_date`` ascending."""
    today = DateValue.today()
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    user_key = "test_user_" + uuid.uuid4().hex[:8]
    for offset in (3, 2, 1, 0):
        await upsert_weight(
            session=session, user_key=user_key,
            log_date=today - TimeDeltaValue(days=offset),
            weight=Decimal("180") + Decimal(offset),
            unit="lb",
            now=now,
        )
    rows = await list_weight_range(
        session=session, user_key=user_key,
        from_date=today - TimeDeltaValue(days=3),
        to_date=today,
    )
    assert len(rows) == 4
    assert rows[0].log_date < rows[-1].log_date


@pytest.mark.asyncio
async def test_delete(session: AsyncSession) -> None:
    """``delete_weight`` returns ``True`` for an existing row and ``False`` on a repeated delete."""
    today = DateValue.today()
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    user_key = "test_user_" + uuid.uuid4().hex[:8]
    await upsert_weight(
        session=session, user_key=user_key, log_date=today,
        weight=Decimal("180"), unit="lb", now=now,
    )
    assert await delete_weight(session=session, user_key=user_key, log_date=today) is True
    assert await delete_weight(session=session, user_key=user_key, log_date=today) is False


@pytest.mark.asyncio
async def test_bootstrap_is_idempotent(session: AsyncSession) -> None:
    """``bootstrap_schema`` is safe to invoke twice in a single process."""
    # If we get here, bootstrap already ran. Run it a second time.
    await db.bootstrap_schema()
