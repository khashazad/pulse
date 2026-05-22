"""HTTP tests for `/calories_daily`.

Exercises the happy path (mocked aggregator returns rows for a date range)
and the two 400 rejections handled by the range validator: inverted
``from`` > ``to`` and oversize ranges. Uses a TestClient with DB pool,
USDA client, and session middleware patched out.
"""

from __future__ import annotations

import os
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from datetime import timedelta as TimeDeltaValue
from datetime import timezone as TimezoneValue
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test")


def _now() -> DateTimeValue:
    """Return the current UTC timestamp as an aware ``datetime``.

    **Outputs:**
    - datetime: ``datetime.now`` in UTC.
    """
    return DateTimeValue.now(tz=TimezoneValue.utc)


@pytest.fixture
def client() -> TestClient:
    """TestClient with DB pool, USDA client, and auth middleware mocked.

    **Outputs:**
    - TestClient: Client whose Bearer-authenticated requests pass auth.
    """
    fut = _now() + TimeDeltaValue(days=7)
    session_repo = AsyncMock()
    session_repo.get.return_value = {"email": "khashzd@gmail.com", "expires_at": fut}
    session_repo.slide.return_value = 1
    session_repo.delete.return_value = 1
    fake_db_session = AsyncMock()
    db_ctx = AsyncMock()
    db_ctx.__aenter__.return_value = fake_db_session
    db_ctx.__aexit__.return_value = None

    with patch("pulse_server.db.init_pool", new_callable=AsyncMock), patch(
        "pulse_server.db.bootstrap_schema", new_callable=AsyncMock
    ), patch("pulse_server.db.close_pool", new_callable=AsyncMock), patch(
        "pulse_server.usda.USDAClient"
    ) as mock_usda_client, patch(
        "pulse_server.auth.middleware.get_session", return_value=db_ctx
    ), patch(
        "pulse_server.auth.middleware.SessionsRepository", return_value=session_repo
    ):
        mock_usda_client.return_value.close = AsyncMock()
        from pulse_server.app import app
        from pulse_server.db import get_session_dependency

        async def _fake_session_dep():
            """Yield a `MagicMock` standing in for the real DB session dependency."""
            session = MagicMock()
            yield session

        app.dependency_overrides[get_session_dependency] = _fake_session_dep
        try:
            with TestClient(app) as test_client:
                yield test_client
        finally:
            app.dependency_overrides.pop(get_session_dependency, None)


HEADERS = {"Authorization": "Bearer tok"}


def test_calories_daily_happy(client: TestClient) -> None:
    """`/calories_daily` returns the aggregator rows verbatim for a valid range."""
    today = DateValue.today()
    with patch(
        "pulse_server.routers.summary.daily_calorie_totals",
        new_callable=AsyncMock,
    ) as fn:
        from pulse_server.models.weight import CaloriesDailyRow
        fn.return_value = [
            CaloriesDailyRow(log_date=today - TimeDeltaValue(days=1), calories=1850),
            CaloriesDailyRow(log_date=today, calories=2100),
        ]
        resp = client.get(
            f"/calories_daily?from={(today - TimeDeltaValue(days=7)).isoformat()}&to={today.isoformat()}",
            headers=HEADERS,
        )
    assert resp.status_code == 200
    rows = resp.json()
    assert len(rows) == 2
    assert rows[0]["calories"] == 1850
    assert rows[1]["calories"] == 2100


def test_calories_daily_rejects_inverted(client: TestClient) -> None:
    """`from` > `to` returns 400."""
    resp = client.get("/calories_daily?from=2025-02-01&to=2025-01-01", headers=HEADERS)
    assert resp.status_code == 400


def test_calories_daily_rejects_oversize(client: TestClient) -> None:
    """A date range wider than the allowed window returns 400."""
    resp = client.get("/calories_daily?from=2024-01-01&to=2025-12-31", headers=HEADERS)
    assert resp.status_code == 400
