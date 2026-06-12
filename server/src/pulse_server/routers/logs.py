"""HTTP endpoint that returns per-day aggregate logs across a date range.

Exposes the ``/logs`` router with a single ``GET`` that yields one
``DailyLogSummary`` per calendar date inside the requested window. Backed by
:class:`LogsRepository` which performs the SQL aggregation server-side.
"""

from __future__ import annotations

from datetime import date as DateValue

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.auth import require_session
from pulse_server.db import get_session_dependency
from pulse_server.models import DailyLogSummary, LogsListResponse
from pulse_server.repositories.logs import LogsRepository
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
            )
            for row in rows
        ]
    )
