"""HTTP endpoints for browsing workouts, activity trends, and activity-type settings."""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.auth import require_session
from pulse_server.config import get_settings
from pulse_server.db import get_session_dependency
from pulse_server.models.activity import (
    ActivityPeriod,
    ActivitySummary,
    ActivityTypeSetting,
    ActivityTypesResponse,
    ActivityWorkoutDetail,
    WorkoutFeedPage,
)
from pulse_server.services.activity_service import (
    DEFAULT_FEED_LIMIT,
    build_summary,
    get_workout_detail,
    list_activity_types,
    list_workout_feed,
    set_activity_type_cardio,
)

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_session)])
TZ = ZoneInfo(settings.timezone)


@router.get("/activity/workouts", response_model=WorkoutFeedPage)
async def get_workout_feed(
    request: Request,
    before: DateTimeValue | None = Query(default=None),
    before_id: UUID | None = Query(default=None),
    limit: int = Query(default=DEFAULT_FEED_LIMIT, ge=1, le=100),
    type: str | None = Query(default=None),
    group: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> WorkoutFeedPage:
    """Return one page of the user's workout feed, newest first.

    **Inputs:**
    - request (Request): Provides ``user_key``.
    - before (datetime | None): ``start_time`` component of the page cursor
      (echo back ``next_before`` from the previous page).
    - before_id (UUID | None): Id tiebreaker for the cursor (echo back
      ``next_before_id`` from the previous page).
    - limit (int): Page size, 1-100.
    - type (str | None): Optional ``activity_type`` filter.
    - group (str | None): Optional group filter — ``"weights"`` or ``"cardio"``.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - WorkoutFeedPage: Items plus the composite ``(next_before, next_before_id)`` cursor.
    """
    return await list_workout_feed(
        session=session,
        user_key=request.state.user_key,
        before=before,
        before_id=before_id,
        limit=limit,
        activity_type=type,
        group=group,
    )


@router.get("/activity/summary", response_model=ActivitySummary)
async def get_activity_summary(
    request: Request,
    period: ActivityPeriod = Query(default="week"),
    anchor: DateValue | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> ActivitySummary:
    """Return the activity trend summary for a period.

    **Inputs:**
    - request (Request): Provides ``user_key`` via ``request.state.user_key``.
    - period (ActivityPeriod): ``week`` | ``month`` | ``year`` (default ``week``).
    - anchor (date | None): Date in the target period; defaults to today in the
      server timezone when not supplied.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - ActivitySummary: The assembled trend summary with totals, deltas, by-type
      breakdown, volume series, and top lifts.
    """
    if anchor is None:
        anchor = DateTimeValue.now(tz=TZ).date()
    return await build_summary(session, request.state.user_key, period, anchor, settings.timezone)


@router.get("/activity/workouts/{workout_id}", response_model=ActivityWorkoutDetail)
async def get_workout_detail_endpoint(
    request: Request,
    workout_id: UUID,
    session: AsyncSession = Depends(get_session_dependency),
) -> ActivityWorkoutDetail:
    """Return full detail for one workout, including Hevy sets when linked.

    **Inputs:**
    - request (Request): Provides ``user_key``.
    - workout_id (UUID): The workout to detail.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - ActivityWorkoutDetail: The workout detail.

    **Raises/Throws:**
    - HTTPException(404): When no workout with that id exists for the user.
    """
    detail = await get_workout_detail(session, request.state.user_key, workout_id)
    if detail is None:
        raise HTTPException(status_code=404, detail="workout not found")
    return detail


class CardioFlagUpdate(BaseModel):
    """Request body for PUT /activity/types/{activity_type}."""

    is_cardio: bool


@router.get("/activity/types", response_model=ActivityTypesResponse)
async def get_activity_types(
    request: Request,
    session: AsyncSession = Depends(get_session_dependency),
) -> ActivityTypesResponse:
    """Return all activity types the user has recorded with their effective cardio flags.

    **Inputs:**
    - request (Request): Provides ``user_key`` via ``request.state.user_key``.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - ActivityTypesResponse: List of activity types sorted by workout count
      descending, each carrying ``activity_type``, ``display_name``, ``count``,
      and the resolved ``is_cardio`` flag.
    """
    return await list_activity_types(session, request.state.user_key)


@router.put("/activity/types/{activity_type}", response_model=ActivityTypeSetting)
async def put_activity_type_cardio(
    request: Request,
    activity_type: str,
    body: CardioFlagUpdate,
    session: AsyncSession = Depends(get_session_dependency),
) -> ActivityTypeSetting:
    """Set the cardio flag for one of the user's recorded activity types.

    **Inputs:**
    - request (Request): Provides ``user_key`` via ``request.state.user_key``.
    - activity_type (str): The Apple Health activity type to update (URL path).
    - body (CardioFlagUpdate): JSON body with ``is_cardio: bool``.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - ActivityTypeSetting: The updated setting with the new ``is_cardio`` value,
      the type's current workout count, and its display name.

    **Raises/Throws:**
    - HTTPException(404): When the activity type has no recorded workouts for
      this user (propagated from the service layer).
    """
    return await set_activity_type_cardio(
        session, request.state.user_key, activity_type, body.is_cardio
    )
