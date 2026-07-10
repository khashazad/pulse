"""HTTP endpoints for per-day aggregate logs and the day-exclusion flag.

Exposes the ``/logs`` router: a ``GET`` that yields one ``DailyLogSummary`` per
calendar date inside the requested window (backed by :class:`LogsRepository`,
which performs the SQL aggregation server-side), and a ``PUT
/logs/{date}/excluded`` that toggles the manual "ignore this day from stats"
flag and returns the day's refreshed summary.
"""

from __future__ import annotations

from datetime import date as DateValue

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.auth import require_session
from pulse_server.db import get_session_dependency
from pulse_server.models import (
    DailyLogSummary,
    DailySummaryResponse,
    DayExclusionRequest,
    LogsListResponse,
)
from pulse_server.repositories.logs import LogsRepository
from pulse_server.services import entries_service, summary_service
from pulse_server.services.date_utils import validate_logs_range

router = APIRouter(dependencies=[Depends(require_session)])


@router.get("/logs", response_model=LogsListResponse)
async def list_logs(
    request: Request,
    from_date: DateValue = Query(alias="from"),
    to_date: DateValue = Query(alias="to"),
    session: AsyncSession = Depends(get_session_dependency),
) -> LogsListResponse:
    """List historical daily logs for the authenticated user across an inclusive date range.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - from_date (date): Inclusive start date (query alias ``from``).
    - to_date (date): Inclusive end date (query alias ``to``).
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - LogsListResponse: Daily aggregate totals and entry counts ordered by date descending.

    **Exceptions:**
    - HTTPException(400): Raised when ``from_date`` is after ``to_date`` or the
      span exceeds ``MAX_RANGE_DAYS``.
    - RuntimeError: Raised when the database pool is not initialized.
    - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    """
    try:
        validate_logs_range(from_date, to_date)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    user_key = request.state.user_key
    repository = LogsRepository(session)
    rows = await repository.list_logs(
        user_key=user_key,
        from_date=from_date,
        to_date=to_date,
    )

    return LogsListResponse(
        logs=[
            DailyLogSummary(
                date=row["log_date"],
                total_calories=int(row["total_calories"]),
                total_protein_g=float(row["total_protein_g"]),
                total_carbs_g=float(row["total_carbs_g"]),
                total_fat_g=float(row["total_fat_g"]),
                entry_count=int(row["entry_count"]),
                excluded=bool(row["excluded"]),
            )
            for row in rows
        ]
    )


@router.put("/logs/{log_date}/excluded", response_model=DailySummaryResponse)
async def set_day_excluded(
    request: Request,
    log_date: DateValue,
    body: DayExclusionRequest,
    session: AsyncSession = Depends(get_session_dependency),
) -> DailySummaryResponse:
    """Toggle the manual "ignore this day from stats" flag for one calendar date.

    Upserts the day's ``daily_logs`` row (so a never-logged day can still be
    excluded), then returns the day's refreshed summary carrying the new
    ``excluded`` value. Setting the flag never alters the day's own entries or
    consumed totals — only whether aggregates skip it.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - log_date (date): Calendar date to toggle (path parameter).
    - body (DayExclusionRequest): New flag value (``{"excluded": bool}``).
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - DailySummaryResponse: The day's summary after the update, with
      ``target``/``remaining`` populated and ``excluded`` reflecting the new
      value. Mirrors the ``GET /summary`` contract (always-populated target).

    **Exceptions:**
    - HTTPException(404): Raised when no target profile exists for the user
      (same contract as ``GET /summary``).
    - sqlalchemy.exc.SQLAlchemyError: Raised when the write or read fails.
    """
    user_key = request.state.user_key
    await entries_service.set_day_excluded(session, user_key, log_date, body.excluded)
    return await summary_service.build_daily_summary(session, user_key, log_date)
