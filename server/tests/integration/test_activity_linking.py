"""Integration test for the ±20-min unique Hevy↔Apple linking pass."""

from __future__ import annotations

import os
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
import pytest_asyncio
from sqlalchemy import insert, select

from pulse_server import db
from pulse_server.activity.repository import link_apple_to_strength
from pulse_server.repositories.tables import (
    apple_workouts,
    daily_activity,
    strength_sets,
    strength_workouts,
)

pytestmark = pytest.mark.integration

TEST_DB_URL = os.environ.get("TEST_DATABASE_URL")

UK = "linktest"
BASE = datetime(2026, 6, 24, 18, 0, tzinfo=UTC)


@pytest_asyncio.fixture
async def session():
    """Yield a clean AsyncSession over the test DB; skip if TEST_DATABASE_URL is unset.

    **Outputs:**
    - AsyncSession: Active session scoped to this test; all four activity tables
      are truncated before the test body runs.

    **Raises/Throws:**
    - pytest.skip: When ``TEST_DATABASE_URL`` is not set in the environment.
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


async def _seed(session, *, apples, strengths):
    """Insert apple/strength rows into the test DB.

    **Inputs:**
    - session (AsyncSession): Active session to execute inserts against.
    - apples (list[tuple]): Each element is ``(id, offset_minutes, activity_type)``.
    - strengths (list[tuple]): Each element is ``(id, offset_minutes)``.

    **Outputs:**
    - None: Rows are inserted but not committed; caller owns the commit.
    """
    for sid, off in strengths:
        await session.execute(
            insert(strength_workouts).values(
                id=sid,
                user_key=UK,
                title="W",
                start_time=BASE + timedelta(minutes=off),
                end_time=BASE + timedelta(minutes=off + 45),
            )
        )
    for aid, off, atype in apples:
        await session.execute(
            insert(apple_workouts).values(
                id=aid,
                user_key=UK,
                activity_type=atype,
                start_time=BASE + timedelta(minutes=off),
                end_time=BASE + timedelta(minutes=off + 45),
            )
        )


@pytest.mark.asyncio
async def test_links_nearest_within_window_uniquely(session) -> None:
    """Each strength workout links the nearest in-window strength-type apple, 1:1."""
    s1, a_near, a_far = uuid4(), uuid4(), uuid4()
    await _seed(
        session,
        strengths=[(s1, 0)],
        apples=[
            (a_near, 2, "TraditionalStrengthTraining"),
            (a_far, 40, "TraditionalStrengthTraining"),
        ],
    )
    await session.commit()

    linked = await link_apple_to_strength(session, UK)
    await session.commit()

    rows = (
        await session.execute(
            select(apple_workouts.c.id, apple_workouts.c.linked_strength_workout_id).where(
                apple_workouts.c.user_key == UK
            )
        )
    ).all()
    by_id = {r[0]: r[1] for r in rows}
    assert linked == 1
    assert by_id[a_near] == s1  # nearest in-window match
    assert by_id[a_far] is None  # outside 20 min → unlinked


@pytest.mark.asyncio
async def test_link_is_idempotent_and_clears_stale(session) -> None:
    """Re-running relinks from scratch; a now-unmatchable prior link is cleared."""
    s1, a1 = uuid4(), uuid4()
    await _seed(
        session,
        strengths=[(s1, 0)],
        apples=[(a1, 90, "TraditionalStrengthTraining")],
    )
    await session.execute(
        apple_workouts.update()
        .where(apple_workouts.c.id == a1)
        .values(linked_strength_workout_id=s1)
    )
    await session.commit()

    linked = await link_apple_to_strength(session, UK)
    await session.commit()

    val = (
        await session.execute(
            select(apple_workouts.c.linked_strength_workout_id).where(apple_workouts.c.id == a1)
        )
    ).scalar_one()
    assert linked == 0
    assert val is None  # 90 min apart → stale link removed
