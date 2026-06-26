"""Integration tests for ActivityReadRepository feed + brief queries."""

from __future__ import annotations

import os
from datetime import UTC, date, datetime, timedelta
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
    page1 = await repo.list_workouts(UK, before=None, before_id=None, limit=2, activity_type=None)
    assert [r["id"] for r in page1] == [ids[0], ids[1]]

    cursor = page1[-1]["start_time"]
    cursor_id = page1[-1]["id"]
    page2 = await repo.list_workouts(
        UK, before=cursor, before_id=cursor_id, limit=2, activity_type=None
    )
    assert [r["id"] for r in page2] == [ids[2]]


async def test_list_workouts_composite_cursor_no_drop_on_tie(session) -> None:
    """Two workouts sharing an exact start_time are both delivered across pages."""
    # Same start_time, different activity_type (so they are distinct apple_workouts rows).
    a, b = uuid4(), uuid4()
    for wid, atype in ((a, "Running"), (b, "Cycling")):
        await session.execute(
            insert(apple_workouts).values(
                id=wid,
                user_key=UK,
                activity_type=atype,
                start_time=T0,
                end_time=T0 + timedelta(minutes=30),
            )
        )
    await session.commit()

    repo = ActivityReadRepository(session)
    page1 = await repo.list_workouts(UK, before=None, before_id=None, limit=1, activity_type=None)
    assert len(page1) == 1
    page2 = await repo.list_workouts(
        UK, before=page1[-1]["start_time"], before_id=page1[-1]["id"], limit=1, activity_type=None
    )
    assert len(page2) == 1
    assert {page1[0]["id"], page2[0]["id"]} == {a, b}  # neither row dropped at the boundary


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


async def test_workouts_in_range_filters_by_date(session) -> None:
    """workouts_in_range returns only workouts whose start date is within bounds."""
    from datetime import date

    inside, outside = uuid4(), uuid4()
    async with session.begin_nested():
        await session.execute(
            insert(apple_workouts).values(
                id=inside,
                user_key=UK,
                activity_type="Running",
                start_time=T0,
                end_time=T0 + timedelta(minutes=30),
                duration_min=30,
                active_energy_cal=300,
            )
        )
        await session.execute(
            insert(apple_workouts).values(
                id=outside,
                user_key=UK,
                activity_type="Running",
                start_time=T0 - timedelta(days=40),
                end_time=T0 - timedelta(days=40) + timedelta(minutes=30),
                duration_min=30,
                active_energy_cal=300,
            )
        )
    repo = ActivityReadRepository(session)
    rows = await repo.workouts_in_range(UK, date(2026, 6, 22), date(2026, 6, 28), tz="UTC")
    assert len(rows) == 1 and rows[0]["activity_type"] == "Running"


async def test_strength_history_returns_joined_rows(session) -> None:
    """strength_history joins sets to workouts and returns date, duration, and set fields."""
    from datetime import date

    sw = uuid4()
    async with session.begin_nested():
        await session.execute(
            insert(strength_workouts).values(
                id=sw,
                user_key=UK,
                title="Leg Day",
                start_time=T0,
                end_time=T0 + timedelta(minutes=45),
            )
        )
        await session.execute(
            insert(strength_sets).values(
                id=uuid4(),
                strength_workout_id=sw,
                user_key=UK,
                exercise_title="Squat",
                set_index=0,
                weight_lbs=225,
                reps=5,
            )
        )
    repo = ActivityReadRepository(session)
    rows = await repo.strength_history(UK, date(2026, 6, 28), tz="UTC")
    assert len(rows) == 1
    r = rows[0]
    assert r["exercise_title"] == "Squat"
    assert r["weight_lbs"] == 225
    assert r["reps"] == 5
    assert r["date"] == date(2026, 6, 24)
    assert r["workout_id"] == sw


async def test_list_workouts_filters_by_group(session) -> None:
    """group='weights' returns only strength types; 'cardio' returns the rest."""
    rows = [
        ("TraditionalStrengthTraining", uuid4()),
        ("FunctionalStrengthTraining", uuid4()),
        ("Running", uuid4()),
        ("Cycling", uuid4()),
    ]
    for i, (atype, wid) in enumerate(rows):
        await session.execute(
            insert(apple_workouts).values(
                id=wid,
                user_key=UK,
                activity_type=atype,
                start_time=T0 - timedelta(hours=i),
                end_time=T0 - timedelta(hours=i) + timedelta(minutes=30),
            )
        )
    await session.commit()
    repo = ActivityReadRepository(session)
    weights = await repo.list_workouts(UK, None, None, 50, None, group="weights")
    assert {r["activity_type"] for r in weights} == {
        "TraditionalStrengthTraining",
        "FunctionalStrengthTraining",
    }
    cardio = await repo.list_workouts(UK, None, None, 50, None, group="cardio")
    assert {r["activity_type"] for r in cardio} == {"Running", "Cycling"}


async def test_workouts_in_range_timezone_bucketing(session) -> None:
    """workouts_in_range uses tz for date bucketing, not UTC."""
    # 2026-06-22 02:30 UTC == 2026-06-21 22:30 America/Toronto (UTC-4 in June).
    # Querying for 2026-06-21 in Toronto must include the workout;
    # querying for 2026-06-22 must exclude it.
    start_utc = datetime(2026, 6, 22, 2, 30, tzinfo=UTC)
    wid = uuid4()
    await session.execute(
        insert(apple_workouts).values(
            id=wid,
            user_key=UK,
            activity_type="Running",
            start_time=start_utc,
            end_time=start_utc + timedelta(minutes=30),
            duration_min=30,
            active_energy_cal=300,
        )
    )
    await session.commit()
    repo = ActivityReadRepository(session)
    rows_jun21 = await repo.workouts_in_range(
        UK, date(2026, 6, 21), date(2026, 6, 21), tz="America/Toronto"
    )
    rows_jun22 = await repo.workouts_in_range(
        UK, date(2026, 6, 22), date(2026, 6, 22), tz="America/Toronto"
    )
    assert len(rows_jun21) == 1, (
        "workout whose UTC date is June 22 should appear on June 21 Toronto"
    )
    assert len(rows_jun22) == 0, "workout should not appear on June 22 Toronto"
