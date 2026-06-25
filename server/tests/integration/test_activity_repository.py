"""Integration tests for activity upserts (idempotency + counts)."""

from __future__ import annotations

import os
from datetime import UTC, datetime

import pytest
import pytest_asyncio
from sqlalchemy import func, select

from pulse_server import db
from pulse_server.activity import repository
from pulse_server.activity.models import (
    AppleWorkout,
    DailyActivity,
    StrengthSet,
    StrengthWorkout,
)
from pulse_server.repositories.tables import (
    apple_workouts,
    daily_activity,
    strength_sets,
    strength_workouts,
)

pytestmark = pytest.mark.integration

TEST_DB_URL = os.environ.get("TEST_DATABASE_URL")


@pytest_asyncio.fixture
async def session():
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


def _workout(activity="Yoga"):
    t = datetime(2026, 6, 13, 18, 0, tzinfo=UTC)
    return AppleWorkout(
        user_key="khash",
        activity_type=activity,
        source_name="Watch",
        start_time=t,
        end_time=t,
        duration_min=30.0,
        active_energy_cal=None,
        basal_energy_cal=None,
        avg_heart_rate=None,
        max_heart_rate=None,
        distance_km=None,
        step_count=None,
        flights_climbed=None,
        indoor=None,
        elevation_ascended_m=None,
        avg_mets=None,
        temperature_f=None,
        humidity_pct=None,
        timezone=None,
        route_gpx_path=None,
    )


@pytest.mark.asyncio
async def test_apple_upsert_is_idempotent(session):
    inserted, updated = await repository.upsert_apple_workouts(session, [_workout()])
    await session.commit()
    assert (inserted, updated) == (1, 0)

    inserted2, updated2 = await repository.upsert_apple_workouts(session, [_workout()])
    await session.commit()
    assert (inserted2, updated2) == (0, 1)

    count = await session.scalar(select(func.count()).select_from(apple_workouts))
    assert count == 1


@pytest.mark.asyncio
async def test_strength_upsert_links_sets_to_workout(session):
    t = datetime(2026, 6, 12, 7, 26, tzinfo=UTC)
    w = StrengthWorkout(
        user_key="khash", title="Chest Day", start_time=t, end_time=t, description=None
    )
    s = StrengthSet(
        user_key="khash",
        workout_title="Chest Day",
        workout_start_time=t,
        exercise_title="Incline Dumbbell Press",
        superset_id=None,
        exercise_notes=None,
        set_index=0,
        set_type="normal",
        weight_lbs=65.0,
        reps=12,
        distance_km=None,
        duration_seconds=None,
        rpe=8.0,
    )
    inserted, _ = await repository.upsert_strength(session, [w], [s])
    await session.commit()
    assert inserted == 2  # 1 workout + 1 set

    joined = await session.scalar(
        select(func.count()).select_from(strength_sets.join(strength_workouts))
    )
    assert joined == 1


@pytest.mark.asyncio
async def test_daily_upsert_is_idempotent(session):
    from datetime import date

    day = DailyActivity(
        user_key="khash",
        date=date(2026, 6, 12),
        active_energy_cal=577.8,
        active_energy_goal=780.0,
        exercise_minutes=55,
        exercise_goal=60,
        stand_hours=7,
        stand_goal=12,
    )
    assert (await repository.upsert_daily_activity(session, [day]))[0] == 1
    await session.commit()
    assert (await repository.upsert_daily_activity(session, [day])) == (0, 1)
    await session.commit()
