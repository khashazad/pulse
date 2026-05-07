from __future__ import annotations

from datetime import date as DateValue

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.auth import require_api_key
from diet_tracker_server.config import get_settings
from diet_tracker_server.db import get_session_dependency
from diet_tracker_server.models import DailySummaryResponse
from diet_tracker_server.services.summary_service import build_daily_summary

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_api_key)])


# Summary: Returns a daily diet summary combining targets, consumed totals, and remaining budget.
# Parameters:
# - summary_date (datetime.date): Date whose diet summary is requested.
# - user_key (str | None): Optional user identifier override.
# Returns:
# - DailySummaryResponse: Per-day targets, consumed totals, remaining totals, and raw entries.
# Raises/Throws:
# - fastapi.HTTPException: Raised with 404 when no target profile exists for the user.
# - RuntimeError: Raised when the database pool is not initialized.
# - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
@router.get("/summary/{summary_date}", response_model=DailySummaryResponse)
async def daily_summary(
    summary_date: DateValue,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> DailySummaryResponse:
    effective_user_key = user_key or settings.default_user_key
    return await build_daily_summary(
        session=session,
        user_key=effective_user_key,
        summary_date=summary_date,
    )
