"""HTTP test for GET /activity/summary."""

from __future__ import annotations

from datetime import UTC, date, datetime
from unittest.mock import AsyncMock, patch
from uuid import uuid4

AUTH_HEADERS = {"Authorization": "Bearer tok"}  # mirrors conftest.AUTH_HEADERS


def test_summary_assembles_totals_deltas_and_groups(rest_client) -> None:
    """The endpoint returns totals, period-over-period deltas, and a by-group list."""
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
    cardio = next(g for g in body["by_group"] if g["group"] == "cardio")
    assert any(t["activity_type"] == "Running" for t in cardio["subtypes"])
    assert body["top_lifts"][0]["exercise_title"] == "Bench"


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
