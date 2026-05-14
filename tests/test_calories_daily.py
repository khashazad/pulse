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
    return DateTimeValue.now(tz=TimezoneValue.utc)


@pytest.fixture
def client() -> TestClient:
    fut = _now() + TimeDeltaValue(days=7)
    session_repo = AsyncMock()
    session_repo.get.return_value = {"email": "khashzd@gmail.com", "expires_at": fut}
    session_repo.slide.return_value = 1
    session_repo.delete.return_value = 1
    fake_db_session = AsyncMock()
    db_ctx = AsyncMock()
    db_ctx.__aenter__.return_value = fake_db_session
    db_ctx.__aexit__.return_value = None

    with patch("diet_tracker_server.db.init_pool", new_callable=AsyncMock), patch(
        "diet_tracker_server.db.bootstrap_schema", new_callable=AsyncMock
    ), patch("diet_tracker_server.db.close_pool", new_callable=AsyncMock), patch(
        "diet_tracker_server.usda.USDAClient"
    ) as mock_usda_client, patch(
        "diet_tracker_server.auth.middleware.get_session", return_value=db_ctx
    ), patch(
        "diet_tracker_server.auth.middleware.SessionsRepository", return_value=session_repo
    ):
        mock_usda_client.return_value.close = AsyncMock()
        from diet_tracker_server.app import app
        from diet_tracker_server.db import get_session_dependency

        async def _fake_session_dep():
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
    today = DateValue.today()
    with patch(
        "diet_tracker_server.routers.summary.daily_calorie_totals",
        new_callable=AsyncMock,
    ) as fn:
        from diet_tracker_server.models.weight import CaloriesDailyRow
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
    resp = client.get("/calories_daily?from=2025-02-01&to=2025-01-01", headers=HEADERS)
    assert resp.status_code == 400


def test_calories_daily_rejects_oversize(client: TestClient) -> None:
    resp = client.get("/calories_daily?from=2024-01-01&to=2025-12-31", headers=HEADERS)
    assert resp.status_code == 400
