"""Integration tests for ActivityReadRepository feed + brief queries."""

from __future__ import annotations

import os
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
import pytest_asyncio
from sqlalchemy import insert

from pulse_server import db
from pulse_server.repositories.activity import ActivityReadRepository
from pulse_server.repositories.tables import (
    apple_workouts,
    daily_activity,
    strength_sets,
    strength_workouts,
)

pytestmark = pytest.mark.integration

TEST_DB_URL = os.environ.get("TEST_DATABASE_URL")

UK = "readrepo"
T0 = datetime(2026, 6, 24, 18, 0, tzinfo=UTC)


@pytest_asyncio.fixture
async def session():
    """Open a test session, wipe activity tables, yield the session, then close the pool.

    **Outputs:**
    - AsyncSession: A live session with a clean slate for the four activity tables.

    **Raises:**
    - pytest.skip.Exception: When ``TEST_DATABASE_URL`` is not set in the environment.
    """
    if TEST_DB_URL is None:
        pytest.skip("TEST_DATABASE_URL not set")
    await db.init_pool(TEST_DB_URL)
    async with db.get_session() as s:
        await s.execute(strength_sets.delete())
        await s.execute(strength_workouts.delete())
        await s.execute(apple_workouts.delete())
        await s.execute(daily_activity.delete())
        await s.commit()
        yield s
    await db.close_pool()


async def test_list_workouts_paginates_newest_first(session) -> None:
    """list_workouts returns rows newest-first and honors the before cursor + limit."""
    ids = [uuid4() for _ in range(3)]
    for i, wid in enumerate(ids):
        await session.execute(
            insert(apple_workouts).values(
                id=wid,
                user_key=UK,
                activity_type="Running",
                start_time=T0 - timedelta(days=i),
                end_time=T0 - timedelta(days=i) + timedelta(minutes=30),
            )
        )
    await session.commit()

    repo = ActivityReadRepository(session)
    page1 = await repo.list_workouts(UK, before=None, limit=2, activity_type=None)
    assert [r["id"] for r in page1] == [ids[0], ids[1]]

    cursor = page1[-1]["start_time"]
    page2 = await repo.list_workouts(UK, before=cursor, limit=2, activity_type=None)
    assert [r["id"] for r in page2] == [ids[2]]


async def test_strength_briefs_aggregate_sets(session) -> None:
    """strength_briefs returns exercise/set counts and summed weight*reps volume."""
    sw = uuid4()
    await session.execute(
        insert(strength_workouts).values(
            id=sw,
            user_key=UK,
            title="Push",
            start_time=T0,
            end_time=T0 + timedelta(minutes=50),
        )
    )
    for i, (ex, w, reps) in enumerate([("Bench", 135, 8), ("Bench", 145, 6), ("Fly", 30, 15)]):
        await session.execute(
            insert(strength_sets).values(
                id=uuid4(),
                strength_workout_id=sw,
                user_key=UK,
                exercise_title=ex,
                set_index=i,
                weight_lbs=w,
                reps=reps,
            )
        )
    await session.commit()

    repo = ActivityReadRepository(session)
    briefs = await repo.strength_briefs([sw])
    assert briefs[sw]["exercise_count"] == 2
    assert briefs[sw]["set_count"] == 3
    assert briefs[sw]["volume_lbs"] == 135 * 8 + 145 * 6 + 30 * 15


async def test_get_workout_and_sets(session) -> None:
    """get_workout returns the apple row; sets_for_workout returns ordered sets."""
    aid, sw = uuid4(), uuid4()
    await session.execute(
        insert(strength_workouts).values(
            id=sw,
            user_key=UK,
            title="Push",
            start_time=T0,
            end_time=T0 + timedelta(minutes=50),
        )
    )
    await session.execute(
        insert(apple_workouts).values(
            id=aid,
            user_key=UK,
            activity_type="TraditionalStrengthTraining",
            start_time=T0,
            end_time=T0 + timedelta(minutes=57),
            active_energy_cal=276,
            linked_strength_workout_id=sw,
        )
    )
    for i, (ex, w, reps) in enumerate([("Bench", 135, 8), ("Bench", 145, 6)]):
        await session.execute(
            insert(strength_sets).values(
                id=uuid4(),
                strength_workout_id=sw,
                user_key=UK,
                exercise_title=ex,
                set_index=i,
                weight_lbs=w,
                reps=reps,
            )
        )
    await session.commit()
    repo = ActivityReadRepository(session)
    row = await repo.get_workout(UK, aid)
    assert row is not None and row["linked_strength_workout_id"] == sw
    sets = await repo.sets_for_workout(sw)
    assert [s["set_index"] for s in sets] == [0, 1]


async def test_get_workout_missing_returns_none(session) -> None:
    """get_workout returns None for an unknown id."""
    repo = ActivityReadRepository(session)
    assert await repo.get_workout(UK, uuid4()) is None
