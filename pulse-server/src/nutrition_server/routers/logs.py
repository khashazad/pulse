from __future__ import annotations

from datetime import date as DateValue

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.auth import require_api_key
from nutrition_server.config import get_settings
from nutrition_server.db import get_session_dependency
from nutrition_server.models import DailyLogSummary, LogsListResponse
from nutrition_server.repositories.logs import LogsRepository

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_api_key)])


# Summary: Lists historical daily logs for a user across a date range.
# Parameters:
# - from_date (datetime.date): Inclusive start date for returned logs.
# - to_date (datetime.date): Inclusive end date for returned logs.
# - user_key (str | None): Optional user identifier override.
# Returns:
# - LogsListResponse: Daily aggregate totals and entry counts ordered by date desc.
# Raises/Throws:
# - RuntimeError: Raised when the database pool is not initialized.
# - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
@router.get("/logs", response_model=LogsListResponse)
async def list_logs(
    from_date: DateValue = Query(alias="from"),
    to_date: DateValue = Query(alias="to"),
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> LogsListResponse:
    if from_date > to_date:
        raise HTTPException(status_code=400, detail="'from' date must be on or before 'to' date")

    effective_user_key = user_key or settings.default_user_key
    repository = LogsRepository(session)
    rows = await repository.list_logs(
        user_key=effective_user_key,
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
