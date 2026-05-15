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
    async with transaction(session):
        deleted = await delete_weight(
            session=session,
            user_key=request.state.user_key,
            log_date=log_date,
        )
    if not deleted:
        raise HTTPException(status_code=404, detail="no weight entry for date")
    return Response(status_code=204)
