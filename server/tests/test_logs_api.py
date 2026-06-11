"""HTTP unit tests for the `/logs` router.

Covers the happy path (200 with serialized per-day aggregates), the
inverted-range 400, the over-cap span 400 (``validate_logs_range`` caps at
``MAX_RANGE_DAYS``, matching the weight/calorie endpoints), and the
equal-bounds single-day range (allowed). The DB and auth middleware are
mocked via the shared ``rest_client`` fixture; the repository is patched at
the router module level, so these tests need no database.
"""

from __future__ import annotations

from datetime import date as DateValue
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

AUTH_HEADERS = {"Authorization": "Bearer tok"}


def _log_row(log_date: DateValue, calories: int = 1800) -> dict:
    """Build a fake daily-log aggregate row dict.

    **Inputs:**
    - log_date (date): The aggregate row's calendar date.
    - calories (int): Total calories for the day.

    **Outputs:**
    - dict: Mapping of the aggregate columns ``LogsRepository.list_logs`` returns.
    """
    return {
        "log_date": log_date,
        "total_calories": calories,
        "total_protein_g": 120.0,
        "total_carbs_g": 180.0,
        "total_fat_g": 60.0,
        "entry_count": 5,
    }


def test_unauthenticated_rejected(rest_client: TestClient) -> None:
    """`GET /logs` without a Bearer token returns 401."""
    assert rest_client.get("/logs?from=2026-01-01&to=2026-01-07").status_code == 401


def test_list_logs_200(rest_client: TestClient) -> None:
    """`GET /logs?from=&to=` returns serialized per-day aggregates from the repository."""
    rows = [_log_row(DateValue(2026, 1, 2), 1800), _log_row(DateValue(2026, 1, 1), 2000)]
    with patch("pulse_server.routers.logs.LogsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.list_logs = AsyncMock(return_value=rows)
        resp = rest_client.get("/logs?from=2026-01-01&to=2026-01-07", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["logs"]) == 2
    assert body["logs"][0]["total_calories"] == 1800
    assert body["logs"][0]["entry_count"] == 5


def test_list_logs_rejects_inverted_range(rest_client: TestClient) -> None:
    """`from` > `to` returns 400."""
    resp = rest_client.get("/logs?from=2026-02-01&to=2026-01-01", headers=AUTH_HEADERS)
    assert resp.status_code == 400


def test_list_logs_accepts_single_day_range(rest_client: TestClient) -> None:
    """An equal-bounds (single-day) range is accepted and queried."""
    with patch("pulse_server.routers.logs.LogsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.list_logs = AsyncMock(return_value=[_log_row(DateValue(2026, 1, 1))])
        resp = rest_client.get("/logs?from=2026-01-01&to=2026-01-01", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    assert len(resp.json()["logs"]) == 1


def test_list_logs_rejects_over_cap_span(rest_client: TestClient) -> None:
    """A span beyond ``MAX_RANGE_DAYS`` returns 400 without touching the repository."""
    with patch("pulse_server.routers.logs.LogsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.list_logs = AsyncMock(return_value=[])
        resp = rest_client.get("/logs?from=2020-01-01&to=2026-01-01", headers=AUTH_HEADERS)
    assert resp.status_code == 400
    instance.list_logs.assert_not_awaited()


def test_list_logs_accepts_full_year_range(rest_client: TestClient) -> None:
    """A full calendar year (the iOS year view's request) stays within the cap."""
    with patch("pulse_server.routers.logs.LogsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.list_logs = AsyncMock(return_value=[])
        resp = rest_client.get("/logs?from=2026-01-01&to=2026-12-31", headers=AUTH_HEADERS)
    assert resp.status_code == 200
