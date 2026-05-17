"""HTTP endpoints for daily-summary and calorie-trend reads.

Exposes ``GET /summary/{date}`` (combined targets + consumed totals +
remaining budget + entries for one day) and ``GET /calories_daily?from&to``
(time-series of daily calorie totals used by trend charts). Both endpoints
defer to :mod:`services.summary_service` for the actual aggregation.
"""

from __future__ import annotations

from datetime import date as DateValue

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.auth import require_session
from diet_tracker_server.db import get_session_dependency
from diet_tracker_server.models import DailySummaryResponse
from diet_tracker_server.models.weight import CaloriesDailyRow
from diet_tracker_server.services.summary_service import (
    build_daily_summary,
    daily_calorie_totals,
)
from diet_tracker_server.services.weight_service import validate_range

router = APIRouter(dependencies=[Depends(require_session)])


@router.get("/summary/{summary_date}", response_model=DailySummaryResponse)
async def daily_summary(
    request: Request,
    summary_date: DateValue,
    session: AsyncSession = Depends(get_session_dependency),
) -> DailySummaryResponse:
    """Return a daily diet summary combining targets, consumed totals, remaining budget, and entries.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - summary_date (date): Date whose diet summary is requested.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - DailySummaryResponse: Per-day targets, consumed totals, remaining totals, and raw entries.

    **Exceptions:**
    - HTTPException(404): Raised when no target profile exists for the user.
    - RuntimeError: Raised when the database pool is not initialized.
    - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    """
    user_key = request.state.user_key
    return await build_daily_summary(
        session=session,
        user_key=user_key,
        summary_date=summary_date,
    )


@router.get("/calories_daily", response_model=list[CaloriesDailyRow])
async def calories_daily(
    request: Request,
    from_: DateValue = Query(alias="from"),
    to: DateValue = Query(...),
    session: AsyncSession = Depends(get_session_dependency),
) -> list[CaloriesDailyRow]:
    """Return per-day calorie totals across an inclusive date range.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - from_ (date): Inclusive start date (query alias ``from``).
    - to (date): Inclusive end date.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - list[CaloriesDailyRow]: One row per day in the requested window.

    **Exceptions:**
    - HTTPException(400): Raised when the date range fails :func:`validate_range`.
    """
    try:
        validate_range(from_, to)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return await daily_calorie_totals(
        session=session,
        user_key=request.state.user_key,
        from_date=from_,
        to_date=to,
    )
