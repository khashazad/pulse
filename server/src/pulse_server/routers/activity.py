"""HTTP endpoints for browsing workouts and activity trends."""

from __future__ import annotations

from datetime import datetime as DateTimeValue

from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.auth import require_session
from pulse_server.db import get_session_dependency
from pulse_server.models.activity import WorkoutFeedPage
from pulse_server.services.activity_service import DEFAULT_FEED_LIMIT, list_workout_feed

router = APIRouter(dependencies=[Depends(require_session)])


@router.get("/activity/workouts", response_model=WorkoutFeedPage)
async def get_workout_feed(
    request: Request,
    before: DateTimeValue | None = Query(default=None),
    limit: int = Query(default=DEFAULT_FEED_LIMIT, ge=1, le=100),
    type: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> WorkoutFeedPage:
    """Return one page of the user's workout feed, newest first.

    **Inputs:**
    - request (Request): Provides ``user_key``.
    - before (datetime | None): Cursor; older-than bound on ``start_time``.
    - limit (int): Page size, 1-100.
    - type (str | None): Optional ``activity_type`` filter.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - WorkoutFeedPage: Items plus the ``next_before`` cursor.
    """
    return await list_workout_feed(
        session=session,
        user_key=request.state.user_key,
        before=before,
        limit=limit,
        activity_type=type,
    )
