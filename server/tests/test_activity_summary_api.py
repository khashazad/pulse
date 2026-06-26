"""HTTP test for GET /activity/summary."""

from __future__ import annotations

from datetime import UTC, date, datetime
from unittest.mock import AsyncMock, patch
from uuid import uuid4

AUTH_HEADERS = {"Authorization": "Bearer tok"}  # mirrors conftest.AUTH_HEADERS


def test_summary_assembles_totals_deltas_and_by_type(rest_client) -> None:
    """The endpoint returns totals, period-over-period deltas, a by-type list, and no by_group."""
    cur = [
        {
            "activity_type": "Running",
            "duration_min": 30,
            "active_energy_cal": 300,
            "start_time": datetime(2026, 6, 24, tzinfo=UTC),
        },
        {
            "activity_type": "TraditionalStrengthTraining",
            "duration_min": 57,
            "active_energy_cal": 276,
            "start_time": datetime(2026, 6, 23, tzinfo=UTC),
        },
    ]
    prev = [
        {
            "activity_type": "Running",
            "duration_min": 30,
            "active_energy_cal": 250,
            "start_time": datetime(2026, 6, 17, tzinfo=UTC),
        }
    ]
    hist = [
        {
            "exercise_title": "Bench",
            "weight_lbs": 155,
            "reps": 6,
            "date": date(2026, 6, 23),
            "duration_min": 57,
            "workout_id": uuid4(),
        }
    ]
    with patch("pulse_server.services.activity_service.ActivityReadRepository") as repo_cls:
        repo = repo_cls.return_value
        repo.workouts_in_range = AsyncMock(side_effect=[cur, prev])
        repo.strength_history = AsyncMock(return_value=hist)
        resp = rest_client.get(
            "/activity/summary?period=week&anchor=2026-06-24", headers=AUTH_HEADERS
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["totals"]["workout_count"] == 2
    assert body["totals"]["total_duration_min"] == 87.0
    assert body["deltas"]["total_active_energy_cal"]["previous"] == 250.0
    # by_type replaces by_group; strength types collapse to "Weights"
    assert "by_group" not in body
    assert any(t["activity_type"] == "Running" for t in body["by_type"])
    assert any(t["activity_type"] == "Weights" for t in body["by_type"])
    assert body["top_lifts"][0]["exercise_title"] == "Bench"


def test_summary_year_has_months_and_by_type_no_by_group(rest_client) -> None:
    """period=year response has months (12 entries), by_type, and no by_group key."""
    cur = [
        {
            "activity_type": "Running",
            "duration_min": 40,
            "active_energy_cal": 350,
            "start_time": datetime(2026, 3, 10, tzinfo=UTC),
            "local_date": date(2026, 3, 10),
        },
        {
            "activity_type": "TraditionalStrengthTraining",
            "duration_min": 55,
            "active_energy_cal": 280,
            "start_time": datetime(2026, 6, 24, tzinfo=UTC),
            "local_date": date(2026, 6, 24),
        },
        {
            "activity_type": "FunctionalStrengthTraining",
            "duration_min": 45,
            "active_energy_cal": 240,
            "start_time": datetime(2026, 6, 23, tzinfo=UTC),
            "local_date": date(2026, 6, 23),
        },
    ]
    with patch("pulse_server.services.activity_service.ActivityReadRepository") as repo_cls:
        repo = repo_cls.return_value
        repo.workouts_in_range = AsyncMock(side_effect=[cur, []])
        repo.strength_history = AsyncMock(return_value=[])
        resp = rest_client.get(
            "/activity/summary?period=year&anchor=2026-06-24", headers=AUTH_HEADERS
        )
    assert resp.status_code == 200
    body = resp.json()
    # No by_group on the wire anymore.
    assert "by_group" not in body
    # 12 MonthRollup entries for the year.
    assert len(body["months"]) == 12
    assert body["months"][0]["month_start"] == "2026-01-01"
    assert body["months"][11]["month_start"] == "2026-12-01"
    # Both strength types merged into a single "Weights" by_type row.
    by_label = {t["activity_type"]: t for t in body["by_type"]}
    assert set(by_label.keys()) == {"Running", "Weights"}
    assert by_label["Weights"]["count"] == 2
    # weeks is empty for year period.
    assert body["weeks"] == []


def test_summary_month_has_weeks_with_per_type_breakdown(rest_client) -> None:
    """period=month response has weeks with per-type sub-breakdown."""
    # June 2026 starts on Monday, so ISO weeks align exactly with the month;
    # 5 weeks: Jun 1-7, Jun 8-14, Jun 15-21, Jun 22-28, Jun 29-30.
    cur = [
        {
            "activity_type": "Running",
            "duration_min": 30,
            "active_energy_cal": 250,
            "start_time": datetime(2026, 6, 2, tzinfo=UTC),
            "local_date": date(2026, 6, 2),
        },
        {
            "activity_type": "TraditionalStrengthTraining",
            "duration_min": 60,
            "active_energy_cal": 300,
            "start_time": datetime(2026, 6, 9, tzinfo=UTC),
            "local_date": date(2026, 6, 9),
        },
    ]
    with patch("pulse_server.services.activity_service.ActivityReadRepository") as repo_cls:
        repo = repo_cls.return_value
        repo.workouts_in_range = AsyncMock(side_effect=[cur, []])
        repo.strength_history = AsyncMock(return_value=[])
        resp = rest_client.get(
            "/activity/summary?period=month&anchor=2026-06-24", headers=AUTH_HEADERS
        )
    assert resp.status_code == 200
    body = resp.json()
    assert "by_group" not in body
    # months is empty for month period.
    assert body["months"] == []
    # June 2026 yields 5 ISO weeks (no clamping needed — starts on Monday).
    assert len(body["weeks"]) == 5
    # First week (Jun 1-7): one Running session.
    w0 = body["weeks"][0]
    assert w0["week_start"] == "2026-06-01"
    assert w0["session_count"] == 1
    assert w0["by_type"][0]["activity_type"] == "Running"
    # Second week (Jun 8-14): one strength session -> "Weights" label.
    w1 = body["weeks"][1]
    assert w1["week_start"] == "2026-06-08"
    assert w1["by_type"][0]["activity_type"] == "Weights"


def test_summary_volume_series_duration_deduped_by_workout(rest_client) -> None:
    """duration_min per bucket equals the workout's minutes, not minutes x set count."""
    wid = uuid4()
    hist = [
        {
            "exercise_title": "Squat",
            "weight_lbs": 225,
            "reps": 5,
            "date": date(2026, 6, 23),
            "duration_min": 57,
            "workout_id": wid,
        },
        {
            "exercise_title": "Deadlift",
            "weight_lbs": 315,
            "reps": 3,
            "date": date(2026, 6, 23),
            "duration_min": 57,
            "workout_id": wid,
        },
    ]
    with patch("pulse_server.services.activity_service.ActivityReadRepository") as repo_cls:
        repo = repo_cls.return_value
        repo.workouts_in_range = AsyncMock(side_effect=[[], []])
        repo.strength_history = AsyncMock(return_value=hist)
        resp = rest_client.get(
            "/activity/summary?period=week&anchor=2026-06-24", headers=AUTH_HEADERS
        )
    assert resp.status_code == 200
    body = resp.json()
    # The two sets share one workout; duration_min for that day should be 57, not 114.
    assert any(b["duration_min"] == 57.0 for b in body["volume_series"])
    assert not any(b["duration_min"] == 114.0 for b in body["volume_series"])
