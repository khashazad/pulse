"""HTTP endpoints for daily weight entries.

Exposes the ``/weight`` router covering range list, single-day fetch, upsert,
and delete. Business validation (range bounds, future-date rejection) and
service plumbing live in :mod:`services.weight_service`; SQL is in
:class:`WeightRepository`.
"""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.auth import require_session
from diet_tracker_server.config import get_settings
from diet_tracker_server.db import get_session_dependency, transaction
from diet_tracker_server.models.weight import WeightEntryResponse, WeightEntryUpsert
from diet_tracker_server.services.weight_service import (
    delete_weight,
    get_weight,
    list_weight_range,
    upsert_weight,
    validate_log_date,
    validate_range,
)

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_session)])
TZ = ZoneInfo(settings.timezone)


@router.get("/weight", response_model=list[WeightEntryResponse])
async def list_weights(
    request: Request,
    from_: DateValue = Query(alias="from"),
    to: DateValue = Query(...),
    session: AsyncSession = Depends(get_session_dependency),
) -> list[WeightEntryResponse]:
    """Return every weight entry for the authenticated user within an inclusive date range.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - from_ (date): Inclusive start date (query alias ``from``).
    - to (date): Inclusive end date.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - list[WeightEntryResponse]: Weight entries ordered by date ascending.

    **Exceptions:**
    - HTTPException(400): Raised when the date range fails :func:`validate_range`.
    """
    try:
        validate_range(from_, to)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return await list_weight_range(
        session=session,
        user_key=request.state.user_key,
        from_date=from_,
        to_date=to,
    )


@router.get("/weight/{log_date}", response_model=WeightEntryResponse)
async def get_weight_endpoint(
    request: Request,
    log_date: DateValue,
    session: AsyncSession = Depends(get_session_dependency),
) -> WeightEntryResponse:
    """Fetch the weight entry recorded for one specific date.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - log_date (date): Calendar date to look up.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - WeightEntryResponse: The stored weight entry.

    **Exceptions:**
    - HTTPException(404): Raised when no weight entry exists for that date.
    """
    row = await get_weight(
        session=session,
        user_key=request.state.user_key,
        log_date=log_date,
    )
    if row is None:
        raise HTTPException(status_code=404, detail="no weight entry for date")
    return row


@router.put("/weight/{log_date}", response_model=WeightEntryResponse)
async def put_weight(
    request: Request,
    log_date: DateValue,
    body: WeightEntryUpsert,
    session: AsyncSession = Depends(get_session_dependency),
) -> WeightEntryResponse:
    """Insert or update the weight entry for one date.

    Validates that ``log_date`` is not in the future relative to the server's
    timezone before delegating to :func:`upsert_weight`.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - log_date (date): Calendar date the reading applies to.
    - body (WeightEntryUpsert): Weight value and original unit (``"lb"`` or ``"kg"``).
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - WeightEntryResponse: The upserted entry.

    **Exceptions:**
    - HTTPException(400): Raised when ``log_date`` fails :func:`validate_log_date` (e.g. future date).
    """
    today = DateTimeValue.now(tz=TZ).date()
    try:
        validate_log_date(log_date, today)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    now = DateTimeValue.now(tz=TZ)
    async with transaction(session):
        return await upsert_weight(
            session=session,
            user_key=request.state.user_key,
            log_date=log_date,
            weight=body.weight,
            unit=body.unit,
            now=now,
        )


@router.delete("/weight/{log_date}", status_code=204)
async def delete_weight_endpoint(
    request: Request,
    log_date: DateValue,
    session: AsyncSession = Depends(get_session_dependency),
) -> Response:
    """Delete the weight entry for one date and return HTTP 204.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - log_date (date): Calendar date whose entry should be removed.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - Response: Empty 204 response.

    **Exceptions:**
    - HTTPException(404): Raised when no weight entry exists for that date.
    """
    async with transaction(session):
        deleted = await delete_weight(
            session=session,
            user_key=request.state.user_key,
            log_date=log_date,
        )
    if not deleted:
        raise HTTPException(status_code=404, detail="no weight entry for date")
    return Response(status_code=204)
