from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.auth import require_api_key
from diet_tracker_server.config import get_settings
from diet_tracker_server.db import get_session_dependency, transaction
from diet_tracker_server.macro_aggregates import sum_food_entry_macros
from diet_tracker_server.models import (
    EntriesCreateRequest,
    EntriesCreateResponse,
    EntriesListResponse,
    FoodEntryResponse,
)
from diet_tracker_server.repositories.entries import EntriesRepository
from diet_tracker_server.services.entries_service import create_entries_with_side_effects
from diet_tracker_server.services.log_ids import daily_log_id

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_api_key)])
TZ = ZoneInfo(settings.timezone)


# Summary: Creates one or more food entries atomically.
# Parameters:
# - body (EntriesCreateRequest): Requested entries plus optional user key override.
# Returns:
# - EntriesCreateResponse: Persisted entries and macro totals (full day when the batch uses one
#   calendar date; sums of the created rows only when dates are mixed).
# Raises/Throws:
# - RuntimeError: Raised when the database pool is not initialized.
# - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
@router.post("/entries", status_code=201, response_model=EntriesCreateResponse)
async def create_entries(
    body: EntriesCreateRequest,
    session: AsyncSession = Depends(get_session_dependency),
) -> EntriesCreateResponse:
    user_key = body.user_key or settings.default_user_key
    now = DateTimeValue.now(tz=TZ)

    created_rows, all_rows = await create_entries_with_side_effects(
        session=session,
        user_key=user_key,
        items=body.items,
        now=now,
    )
    created = [FoodEntryResponse(**row) for row in created_rows]
    all_entries = [FoodEntryResponse(**row) for row in all_rows]

    return EntriesCreateResponse(entries=created, daily_totals=sum_food_entry_macros(all_entries))


# Summary: Lists all entries for a user's requested log date.
# Parameters:
# - log_date (datetime.date): Date filter for selecting entries.
# - user_key (str | None): Optional user identifier override.
# Returns:
# - EntriesListResponse: Date-scoped entries with aggregate macros.
# Raises/Throws:
# - RuntimeError: Raised when the database pool is not initialized.
# - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
@router.get("/entries", response_model=EntriesListResponse)
async def list_entries(
    log_date: DateValue = Query(..., alias="date"),
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> EntriesListResponse:
    effective_user_key = user_key or settings.default_user_key
    repository = EntriesRepository(session)
    daily_log = daily_log_id(effective_user_key, log_date)
    rows = await repository.list_entries_by_daily_log_id(daily_log)

    entries = [FoodEntryResponse(**row) for row in rows]
    return EntriesListResponse(date=log_date, entries=entries, totals=sum_food_entry_macros(entries))


# Summary: Deletes a single food entry by ID.
# Parameters:
# - entry_id (UUID): UUID identifying the food entry row.
# Returns:
# - None: Endpoint returns HTTP 204 when deletion succeeds.
# Raises/Throws:
# - fastapi.HTTPException: Raised with 404 when the entry does not exist.
# - RuntimeError: Raised when the database pool is not initialized.
# - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
@router.delete("/entries/{entry_id}", status_code=204)
async def delete_entry(
    entry_id: UUID,
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    repository = EntriesRepository(session)
    async with transaction(session):
        is_deleted = await repository.delete_entry(entry_id)
        if not is_deleted:
            raise HTTPException(status_code=404, detail="Entry not found")
