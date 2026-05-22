"""HTTP endpoints for logging and listing individual food entries.

Exposes the ``/entries`` router covering atomic multi-entry creation
(``POST``), single-date listing with macro totals (``GET``), and entry
deletion (``DELETE``). Aggregation and side-effects (memory writes, daily-log
upsert) live in :mod:`services.entries_service`.
"""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.auth import require_session
from pulse_server.config import get_settings
from pulse_server.db import get_session_dependency, transaction
from pulse_server.macro_aggregates import sum_food_entry_macros
from pulse_server.models import (
    EntriesCreateRequest,
    EntriesCreateResponse,
    EntriesListResponse,
    FoodEntryResponse,
)
from pulse_server.repositories.entries import EntriesRepository
from pulse_server.services.entries_service import create_entries_with_side_effects
from pulse_server.services.log_ids import daily_log_id

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_session)])
TZ = ZoneInfo(settings.timezone)


@router.post("/entries", status_code=201, response_model=EntriesCreateResponse)
async def create_entries(
    request: Request,
    body: EntriesCreateRequest,
    session: AsyncSession = Depends(get_session_dependency),
) -> EntriesCreateResponse:
    """Create one or more food entries atomically and return updated daily totals.

    Delegates to :func:`create_entries_with_side_effects` which also upserts
    memory pointers and the daily-log aggregate row.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - body (EntriesCreateRequest): Items to insert.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - EntriesCreateResponse: The newly created entries plus macro totals — full
      day when the batch covers a single date, otherwise sums over just the
      created rows.

    **Exceptions:**
    - RuntimeError: Raised when the database pool is not initialized.
    - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    """
    user_key = request.state.user_key
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


@router.get("/entries", response_model=EntriesListResponse)
async def list_entries(
    request: Request,
    log_date: DateValue = Query(..., alias="date"),
    session: AsyncSession = Depends(get_session_dependency),
) -> EntriesListResponse:
    """List every entry belonging to the user's daily log for ``log_date``.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - log_date (date): Calendar date filter (query alias ``date``).
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - EntriesListResponse: The day's entries together with aggregate macro totals.

    **Exceptions:**
    - RuntimeError: Raised when the database pool is not initialized.
    - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    """
    user_key = request.state.user_key
    repository = EntriesRepository(session)
    daily_log = daily_log_id(user_key, log_date)
    rows = await repository.list_entries_by_daily_log_id(daily_log)

    entries = [FoodEntryResponse(**row) for row in rows]
    return EntriesListResponse(date=log_date, entries=entries, totals=sum_food_entry_macros(entries))


@router.delete("/entries/{entry_id}", status_code=204)
async def delete_entry(
    request: Request,
    entry_id: UUID,
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    """Delete a single food entry by id and return HTTP 204.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - entry_id (UUID): Food-entry primary key.
    - session (AsyncSession): DB session dependency.

    **Exceptions:**
    - HTTPException(404): Raised when no entry with that id exists.
    - RuntimeError: Raised when the database pool is not initialized.
    - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    """
    repository = EntriesRepository(session)
    async with transaction(session):
        is_deleted = await repository.delete_entry(entry_id, request.state.user_key)
        if not is_deleted:
            raise HTTPException(status_code=404, detail="Entry not found")
