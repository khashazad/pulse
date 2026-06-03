"""Shared date-range and log-date validators.

Houses the calendar-range guards used by the weight, summary/calorie, and logs
read paths so the bounds checks live in one place rather than being copied into
each router. Each validator raises :class:`ValueError` with a caller-specific
message; routers/services translate that into an HTTP 400.
"""

from __future__ import annotations

from datetime import date as DateValue

MAX_RANGE_DAYS = 366
MAX_PAST_YEARS = 5


def validate_range(from_date: DateValue, to_date: DateValue) -> None:
    """Validate an inclusive date range for the weight and calorie-trend reads.

    **Inputs:**
    - from_date (DateValue): Inclusive lower bound.
    - to_date (DateValue): Inclusive upper bound.

    **Outputs:**
    - None: Returns nothing when the range is valid.

    **Raises:**
    - ValueError: Raised when ``from_date > to_date`` or the span exceeds
      ``MAX_RANGE_DAYS``.
    """
    if from_date > to_date:
        raise ValueError("from must be <= to")
    if (to_date - from_date).days > MAX_RANGE_DAYS:
        raise ValueError(f"range cannot exceed {MAX_RANGE_DAYS} days")


def validate_logs_range(from_date: DateValue, to_date: DateValue) -> None:
    """Validate the inclusive date range for the historical ``/logs`` read.

    Unlike :func:`validate_range`, the logs endpoint only rejects a reversed
    range (no maximum span) and emits its own ``'from' date must be on or
    before 'to' date`` message; both behaviors are preserved verbatim.

    **Inputs:**
    - from_date (DateValue): Inclusive start date.
    - to_date (DateValue): Inclusive end date.

    **Outputs:**
    - None: Returns nothing when the range is valid.

    **Raises:**
    - ValueError: Raised when ``from_date`` is after ``to_date``.
    """
    if from_date > to_date:
        raise ValueError("'from' date must be on or before 'to' date")


def validate_log_date(log_date: DateValue, today: DateValue) -> None:
    """Validate a single ``log_date`` for upsert: not future, not too far in the past.

    **Inputs:**
    - log_date (DateValue): Date the weight reading applies to.
    - today (DateValue): Caller-supplied current date (UTC).

    **Outputs:**
    - None: Returns nothing when the date is valid.

    **Raises:**
    - ValueError: Raised when ``log_date`` is later than ``today`` or older
      than ``MAX_PAST_YEARS`` years.
    """
    if log_date > today:
        raise ValueError("cannot log weight in the future")
    if (today - log_date).days > MAX_PAST_YEARS * 366:
        raise ValueError("date too far in past")
