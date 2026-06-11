"""Tests for ``parse_consumed_at`` in :mod:`mcp.context`.

Covers the single ``consumed_at`` argument shared by ``log_food`` and
``log_meal``: accepts both ``YYYY-MM-DD`` (expanded to noon in the server
timezone) and ISO-8601 timestamps (naive timestamps get the server tz),
rejects garbage strings, and returns ``None`` for ``None``.
"""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

import pytest
from fastmcp.exceptions import ToolError

from pulse_server.mcp.context import parse_consumed_at as _parse_consumed_at

TZ = ZoneInfo("America/Toronto")


def test_returns_none_when_value_missing() -> None:
    """``None`` input → ``None`` output so callers fall back to ``now``."""
    assert _parse_consumed_at(None, TZ) is None


def test_date_only_expands_to_noon_in_tz() -> None:
    """``YYYY-MM-DD`` expands to noon of that day in the server timezone."""
    parsed = _parse_consumed_at("2026-05-20", TZ)
    assert parsed == datetime(2026, 5, 20, 12, 0, tzinfo=TZ)


def test_naive_iso_timestamp_gets_tz() -> None:
    """A naive ISO timestamp is stamped with the server timezone."""
    parsed = _parse_consumed_at("2026-05-20T19:30:00", TZ)
    assert parsed == datetime(2026, 5, 20, 19, 30, tzinfo=TZ)


def test_aware_iso_timestamp_is_preserved() -> None:
    """A tz-aware ISO timestamp is preserved verbatim (no re-stamping)."""
    parsed = _parse_consumed_at("2026-05-20T19:30:00-04:00", TZ)
    assert parsed is not None
    assert parsed.utcoffset() is not None
    assert parsed == datetime.fromisoformat("2026-05-20T19:30:00-04:00")


def test_garbage_raises_tool_error() -> None:
    """Strings that are neither a date nor ISO-8601 raise ``ToolError``."""
    with pytest.raises(ToolError):
        _parse_consumed_at("not a date", TZ)
