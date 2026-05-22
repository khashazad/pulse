"""Weight-entry business logic: unit normalization, range validation, and CRUD.

Normalizes incoming weights to pounds at the service boundary so the
repository layer only ever stores one unit, while still recording the
original source unit. Exposes upsert / range-list / single-day / delete
operations and the two validation helpers (:func:`validate_range`,
:func:`validate_log_date`) used by callers before hitting the repository.
"""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from decimal import ROUND_HALF_EVEN, Decimal
from typing import Literal

from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.models.weight import WeightEntryResponse
from pulse_server.repositories.weight import WeightRepository


KG_TO_LB = Decimal("2.20462262")
MAX_RANGE_DAYS = 366
MAX_PAST_YEARS = 5


def normalize_to_lb(value: Decimal, unit: Literal["lb", "kg"]) -> Decimal:
    """Convert a weight value to pounds, rounded to two decimal places (banker's rounding).

    **Inputs:**
    - value (Decimal): Raw weight value as entered by the user.
    - unit (Literal["lb", "kg"]): Unit the value is expressed in.

    **Outputs:**
    - Decimal: Weight in pounds, quantized to ``0.01`` using
      ``ROUND_HALF_EVEN``.
    """
    if unit == "lb":
        return value.quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)
    return (value * KG_TO_LB).quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)


def validate_range(from_date: DateValue, to_date: DateValue) -> None:
    """Validate an inclusive date range for the weight list endpoint.

    **Inputs:**
    - from_date (DateValue): Inclusive lower bound.
    - to_date (DateValue): Inclusive upper bound.

    **Exceptions:**
    - ValueError: Raised when ``from_date > to_date`` or the span exceeds
      ``MAX_RANGE_DAYS``.
    """
    if from_date > to_date:
        raise ValueError("from must be <= to")
    if (to_date - from_date).days > MAX_RANGE_DAYS:
        raise ValueError(f"range cannot exceed {MAX_RANGE_DAYS} days")


def validate_log_date(log_date: DateValue, today: DateValue) -> None:
    """Validate a single ``log_date`` for upsert: not future, not too far in the past.

    **Inputs:**
    - log_date (DateValue): Date the weight reading applies to.
    - today (DateValue): Caller-supplied current date (UTC).

    **Exceptions:**
    - ValueError: Raised when ``log_date`` is later than ``today`` or older
      than ``MAX_PAST_YEARS`` years.
    """
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
    """Normalize a weight to pounds and upsert it for ``(user_key, log_date)``.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session.
    - user_key (str): Owning user's scoping key.
    - log_date (DateValue): Date the reading applies to.
    - weight (Decimal): Raw weight value as entered.
    - unit (Literal["lb", "kg"]): Unit of ``weight``; recorded as
      ``source_unit`` on the row.
    - now (DateTimeValue): UTC timestamp stamped as the row's mtime.

    **Outputs:**
    - WeightEntryResponse: The upserted weight entry.

    **Exceptions:**
    - sqlalchemy.exc.SQLAlchemyError: Raised when the upsert fails.
    """
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
    """List weight entries for ``user_key`` in an inclusive date range, validated.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session.
    - user_key (str): Owning user's scoping key.
    - from_date (DateValue): Inclusive lower bound on ``log_date``.
    - to_date (DateValue): Inclusive upper bound on ``log_date``.

    **Outputs:**
    - list[WeightEntryResponse]: Entries ordered by ``log_date`` ascending.

    **Exceptions:**
    - ValueError: Raised when the range is invalid (see
      :func:`validate_range`).
    - sqlalchemy.exc.SQLAlchemyError: Raised when the query fails.
    """
    validate_range(from_date, to_date)
    repo = WeightRepository(session)
    rows = await repo.list_range(user_key=user_key, from_date=from_date, to_date=to_date)
    return [WeightEntryResponse(**row) for row in rows]


async def get_weight(
    session: AsyncSession,
    user_key: str,
    log_date: DateValue,
) -> WeightEntryResponse | None:
    """Fetch a single-day weight entry, if one exists.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session.
    - user_key (str): Owning user's scoping key.
    - log_date (DateValue): Date to look up.

    **Outputs:**
    - WeightEntryResponse | None: The entry, or ``None`` when no row exists
      for that day.

    **Exceptions:**
    - sqlalchemy.exc.SQLAlchemyError: Raised when the query fails.
    """
    repo = WeightRepository(session)
    row = await repo.get_by_date(user_key=user_key, log_date=log_date)
    return WeightEntryResponse(**row) if row else None


async def delete_weight(
    session: AsyncSession,
    user_key: str,
    log_date: DateValue,
) -> bool:
    """Delete the weight entry for ``(user_key, log_date)``.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session.
    - user_key (str): Owning user's scoping key.
    - log_date (DateValue): Date of the entry to delete.

    **Outputs:**
    - bool: ``True`` when a row was removed, ``False`` when no matching row
      existed.

    **Exceptions:**
    - sqlalchemy.exc.SQLAlchemyError: Raised when the delete fails.
    """
    repo = WeightRepository(session)
    return await repo.delete(user_key=user_key, log_date=log_date)
