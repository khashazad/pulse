"""End-to-end test of the import script over the parser fixtures."""

from __future__ import annotations

import os
from pathlib import Path

import pytest
import pytest_asyncio
from sqlalchemy import func, select

from pulse_server import db
from pulse_server.repositories.tables import (
    apple_workouts,
    daily_activity,
    strength_sets,
    strength_workouts,
)
from pulse_server.scripts.import_health_data import run_import

pytestmark = pytest.mark.integration

TEST_DB_URL = os.environ.get("TEST_DATABASE_URL")
FIXTURES = Path(__file__).parents[1] / "fixtures" / "activity"


@pytest_asyncio.fixture(autouse=True)
async def _clean():
    if TEST_DB_URL is None:
        pytest.skip("TEST_DATABASE_URL not set")
    await db.init_pool(TEST_DB_URL)
    async with db.get_session() as s:
        await s.execute(strength_sets.delete())
        await s.execute(strength_workouts.delete())
        await s.execute(apple_workouts.delete())
        await s.execute(daily_activity.delete())
        await s.commit()
    await db.close_pool()
    yield


@pytest.mark.asyncio
async def test_run_import_populates_all_tables():
    summary = await run_import(
        apple_path=str(FIXTURES / "apple_sample.xml"),
        hevy_path=str(FIXTURES / "hevy_sample.csv"),
        user_key="khash",
    )
    assert summary["apple_workouts"] == (2, 0)
    assert summary["daily_activity"] == (2, 0)
    assert summary["strength"][0] == 5  # 2 workouts + 3 sets inserted

    await db.init_pool(TEST_DB_URL)
    async with db.get_session() as s:
        assert await s.scalar(select(func.count()).select_from(apple_workouts)) == 2
        assert await s.scalar(select(func.count()).select_from(strength_sets)) == 3
        assert await s.scalar(select(func.count()).select_from(daily_activity)) == 2
    await db.close_pool()


@pytest.mark.asyncio
async def test_run_import_is_idempotent():
    args = {
        "apple_path": str(FIXTURES / "apple_sample.xml"),
        "hevy_path": str(FIXTURES / "hevy_sample.csv"),
        "user_key": "khash",
    }
    await run_import(**args)
    summary = await run_import(**args)
    assert summary["apple_workouts"] == (0, 2)
    assert summary["daily_activity"] == (0, 2)  # 2 rows updated, none inserted
    assert summary["strength"][0] == 0  # nothing newly inserted on re-run
    assert summary["strength"][1] == 5  # 2 workouts + 3 sets all updated
