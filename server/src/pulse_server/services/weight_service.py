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
from pulse_server.services.date_utils import (
    MAX_PAST_YEARS,
    MAX_RANGE_DAYS,
    validate_log_date,
    validate_range,
)

__all__ = [
    "KG_TO_LB",
    "MAX_PAST_YEARS",
    "MAX_RANGE_DAYS",
    "delete_weight",
    "get_weight",
    "list_weight_range",
    "normalize_to_lb",
    "upsert_weight",
    "validate_log_date",
    "validate_range",
]

KG_TO_LB = Decimal("2.20462262")


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


async def upsert_weight(
    session: AsyncSession,
    user_key: str,
    log_date: DateValue,
    weight: Decimal,
    unit: Literal["lb", "kg"],
    now: DateTimeValue,
) -> WeightEntryResponse:
    """Normalize a weight to pounds and upsert it for ``(user_key, log_date)``.

    Validates ``log_date`` (not future relative to ``now``, not older than
    ``MAX_PAST_YEARS`` years) before persisting so the service contract is
    self-contained.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session.
    - user_key (str): Owning user's scoping key.
    - log_date (DateValue): Date the reading applies to.
    - weight (Decimal): Raw weight value as entered.
    - unit (Literal["lb", "kg"]): Unit of ``weight``; recorded as
      ``source_unit`` on the row.
    - now (DateTimeValue): UTC timestamp stamped as the row's mtime; its
      calendar date is used as "today" for :func:`validate_log_date`.

    **Outputs:**
    - WeightEntryResponse: The upserted weight entry.

    **Raises:**
    - ValueError: Raised when ``log_date`` fails :func:`validate_log_date`
      (future date or too far in the past).
    - sqlalchemy.exc.SQLAlchemyError: Raised when the upsert fails.
    """
    validate_log_date(log_date, now.date())
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
