"""Tests for ``_effective_log_date`` in :mod:`services.entries_service`.

Verifies the precedence rules used when an entry's daily-log calendar date
must be resolved from an optional ``consumed_at`` against the request-scoped
``now``.
"""

from __future__ import annotations

from datetime import date, datetime
from zoneinfo import ZoneInfo

from pulse_server.services.entries_service import _effective_log_date


TZ = ZoneInfo("America/Toronto")


def test_consumed_at_derives_date_in_request_tz() -> None:
    """``consumed_at`` is projected into ``now``'s tz to derive the calendar date."""
    now = datetime(2026, 5, 19, 12, 0, tzinfo=TZ)
    # 02:00 UTC = 22:00 the previous day in Toronto (EDT)
    consumed = datetime(2026, 5, 20, 2, 0, tzinfo=ZoneInfo("UTC"))
    assert _effective_log_date(consumed, now) == date(2026, 5, 19)


def test_falls_back_to_now_date() -> None:
    """Missing ``consumed_at`` → ``now.date()``."""
    now = datetime(2026, 5, 19, 12, 0, tzinfo=TZ)
    assert _effective_log_date(None, now) == date(2026, 5, 19)


def test_consumed_at_naive_uses_its_own_date() -> None:
    """Naive ``consumed_at`` (no tzinfo) returns its own ``.date()`` without conversion."""
    now = datetime(2026, 5, 19, 12, 0, tzinfo=TZ)
    consumed_naive = datetime(2026, 6, 1, 9, 0)
    assert _effective_log_date(consumed_naive, now) == date(2026, 6, 1)


def test_consumed_at_same_tz_passthrough() -> None:
    """When ``consumed_at`` is already in ``now``'s tz the date is its own date."""
    now = datetime(2026, 5, 19, 12, 0, tzinfo=TZ)
    consumed = datetime(2026, 5, 22, 19, 30, tzinfo=TZ)
    assert _effective_log_date(consumed, now) == date(2026, 5, 22)
