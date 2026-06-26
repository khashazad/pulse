"""Integration test: the cardio-flag write actually commits.

Regression guard for the router omitting ``async with transaction(session)``.
The request-scoped session yielded by ``get_session_dependency`` is closed (not
committed) at request end, so a write that is not wrapped in a transaction is
silently rolled back. This drives the real ``put_activity_type_cardio`` router
function with a request-scoped session that is NOT manually committed, then
reads the row back through a separate session to prove it persisted.
"""

from __future__ import annotations

import os
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from uuid import uuid4

import pytest
import pytest_asyncio
from sqlalchemy import insert, select

from pulse_server import db
from pulse_server.repositories.tables import activity_type_settings, apple_workouts
from pulse_server.routers.activity import CardioFlagUpdate, put_activity_type_cardio

pytestmark = pytest.mark.integration

TEST_DB_URL = os.environ.get("TEST_DATABASE_URL")

UK = "persisttest"
T0 = datetime(2026, 6, 24, 18, 0, tzinfo=UTC)


@pytest_asyncio.fixture
async def clean_pool():
    """Open the pool, wipe this test's rows, yield, then close the pool.

    **Outputs:**
    - None: yields control with ``apple_workouts`` and ``activity_type_settings``
      cleared for ``UK``.

    **Raises:**
    - pytest.skip.Exception: When ``TEST_DATABASE_URL`` is not set.
    """
    if TEST_DB_URL is None:
        pytest.skip("TEST_DATABASE_URL not set")
    await db.init_pool(TEST_DB_URL)
    async with db.get_session() as s:
        await s.execute(apple_workouts.delete().where(apple_workouts.c.user_key == UK))
        await s.execute(
            activity_type_settings.delete().where(activity_type_settings.c.user_key == UK)
        )
        await s.commit()
    yield
    await db.close_pool()


async def test_put_cardio_flag_commits_across_request_scope(clean_pool) -> None:
    """The cardio toggle persists after a request-scoped session closes without an explicit commit.

    Seeds a ``Running`` workout so the type validates, calls the router function
    on a session that is never manually committed (mirroring FastAPI's
    request-scoped dependency), then asserts the override row is readable through
    a fresh session — which only holds if the router opened a transaction.
    """
    async with db.get_session() as seed:
        await seed.execute(
            insert(apple_workouts).values(
                id=uuid4(),
                user_key=UK,
                activity_type="Running",
                start_time=T0,
                end_time=T0 + timedelta(minutes=30),
            )
        )
        await seed.commit()

    request = SimpleNamespace(state=SimpleNamespace(user_key=UK))
    async with db.get_session() as req_session:
        result = await put_activity_type_cardio(
            request=request,  # type: ignore[arg-type]
            activity_type="Running",
            body=CardioFlagUpdate(is_cardio=False),
            session=req_session,
        )
        # Deliberately NO req_session.commit() — the router's transaction() must commit.

    assert result.is_cardio is False

    async with db.get_session() as verify:
        row = (
            await verify.execute(
                select(activity_type_settings.c.is_cardio).where(
                    activity_type_settings.c.user_key == UK,
                    activity_type_settings.c.activity_type == "Running",
                )
            )
        ).first()
    assert row is not None, "cardio override was rolled back — router missing transaction()"
    assert row.is_cardio is False
