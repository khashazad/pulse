"""Activity read business logic: assemble feed pages, detail, and summaries
from ActivityReadRepository rows into the response DTOs."""

from __future__ import annotations

from datetime import datetime as DateTimeValue

from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.models.activity import (
    ActivityWorkoutSummary,
    StrengthBrief,
    WorkoutFeedPage,
)
from pulse_server.repositories.activity import ActivityReadRepository

MAX_FEED_LIMIT = 100
DEFAULT_FEED_LIMIT = 50


async def list_workout_feed(
    session: AsyncSession,
    user_key: str,
    before: DateTimeValue | None,
    limit: int,
    activity_type: str | None,
) -> WorkoutFeedPage:
    """Build one page of the workout feed, enriching strength rows with briefs.

    **Inputs:**
    - session (AsyncSession): Active session.
    - user_key (str): Owning user's scoping key.
    - before (datetime | None): Cursor; return workouts strictly older than this.
    - limit (int): Page size (clamped to ``MAX_FEED_LIMIT``).
    - activity_type (str | None): Optional exact type filter.

    **Outputs:**
    - WorkoutFeedPage: Items newest-first plus the ``next_before`` cursor (None when
      the page was not full).
    """
    limit = max(1, min(limit, MAX_FEED_LIMIT))
    repo = ActivityReadRepository(session)
    rows = await repo.list_workouts(user_key, before, limit, activity_type)
    linked_ids = [r["linked_strength_workout_id"] for r in rows if r["linked_strength_workout_id"]]
    briefs = await repo.strength_briefs(linked_ids) if linked_ids else {}
    items: list[ActivityWorkoutSummary] = []
    for r in rows:
        sw_id = r["linked_strength_workout_id"]
        brief = briefs.get(sw_id) if sw_id else None
        items.append(
            ActivityWorkoutSummary(
                id=r["id"],
                activity_type=r["activity_type"],
                start_time=r["start_time"],
                end_time=r["end_time"],
                duration_min=r["duration_min"],
                active_energy_cal=r["active_energy_cal"],
                distance_km=r["distance_km"],
                has_strength_detail=brief is not None,
                strength_brief=StrengthBrief(**brief) if brief else None,
            )
        )
    next_before = rows[-1]["start_time"] if len(rows) == limit else None
    return WorkoutFeedPage(items=items, next_before=next_before)
