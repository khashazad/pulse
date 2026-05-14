from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from decimal import ROUND_HALF_EVEN, Decimal
from typing import Literal

from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.models.weight import WeightEntryResponse
from diet_tracker_server.repositories.weight import WeightRepository


KG_TO_LB = Decimal("2.20462262")
MAX_RANGE_DAYS = 366
MAX_PAST_YEARS = 5


def normalize_to_lb(value: Decimal, unit: Literal["lb", "kg"]) -> Decimal:
    if unit == "lb":
        return value.quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)
    return (value * KG_TO_LB).quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)


def validate_range(from_date: DateValue, to_date: DateValue) -> None:
    if from_date > to_date:
        raise ValueError("from must be <= to")
    if (to_date - from_date).days > MAX_RANGE_DAYS:
        raise ValueError(f"range cannot exceed {MAX_RANGE_DAYS} days")


def validate_log_date(log_date: DateValue, today: DateValue) -> None:
    if log_date > today:
        raise ValueError("cannot log weight in the future")
    if (today - log_date).days > MAX_PAST_YEARS * 366:
        raise ValueError("date too far in past")


async def upsert_weight(
    session: AsyncSession,
    user_key: str,
    log_date: DateValue,
    weight: Decimal,
    unit: Literal["lb", "kg"],
    now: DateTimeValue,
) -> WeightEntryResponse:
    weight_lb = normalize_to_lb(weight, unit)
    repo = WeightRepository(session)
    row = await repo.upsert(
        user_key=user_key,
        log_date=log_date,
        weight_lb=weight_lb,
        source_unit=unit,
        updated_at=now,
    )
    return WeightEntryResponse(**row)


async def list_weight_range(
    session: AsyncSession,
    user_key: str,
    from_date: DateValue,
    to_date: DateValue,
) -> list[WeightEntryResponse]:
    validate_range(from_date, to_date)
    repo = WeightRepository(session)
    rows = await repo.list_range(user_key=user_key, from_date=from_date, to_date=to_date)
    return [WeightEntryResponse(**row) for row in rows]


async def get_weight(
    session: AsyncSession,
    user_key: str,
    log_date: DateValue,
) -> WeightEntryResponse | None:
    repo = WeightRepository(session)
    row = await repo.get_by_date(user_key=user_key, log_date=log_date)
    return WeightEntryResponse(**row) if row else None


async def delete_weight(
    session: AsyncSession,
    user_key: str,
    log_date: DateValue,
) -> bool:
    repo = WeightRepository(session)
    return await repo.delete(user_key=user_key, log_date=log_date)
