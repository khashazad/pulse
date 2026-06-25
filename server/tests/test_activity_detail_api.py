"""HTTP test for GET /activity/workouts/{id}."""

from __future__ import annotations

from datetime import UTC, datetime
from unittest.mock import AsyncMock, patch
from uuid import uuid4

AUTH_HEADERS = {"Authorization": "Bearer tok"}  # mirrors conftest.AUTH_HEADERS


def test_detail_groups_sets_into_exercises(rest_client) -> None:
    """Detail groups sets by exercise, computes volume + top set, fills Apple stats."""
    aid, sw = uuid4(), uuid4()
    workout = {
        "id": aid,
        "activity_type": "TraditionalStrengthTraining",
        "start_time": datetime(2026, 6, 24, 18, 0, tzinfo=UTC),
        "end_time": datetime(2026, 6, 24, 18, 57, tzinfo=UTC),
        "duration_min": 57,
        "active_energy_cal": 276,
        "basal_energy_cal": 90,
        "avg_heart_rate": 132,
        "max_heart_rate": 158,
        "distance_km": None,
        "elevation_ascended_m": None,
        "step_count": None,
        "flights_climbed": None,
        "avg_mets": 6.2,
        "indoor": True,
        "linked_strength_workout_id": sw,
    }
    sets = [
        {
            "set_index": 0,
            "set_type": "normal",
            "weight_lbs": 135,
            "reps": 8,
            "rpe": 7,
            "exercise_title": "Bench",
            "superset_id": None,
            "distance_km": None,
            "duration_seconds": None,
        },
        {
            "set_index": 1,
            "set_type": "normal",
            "weight_lbs": 145,
            "reps": 6,
            "rpe": 9,
            "exercise_title": "Bench",
            "superset_id": None,
            "distance_km": None,
            "duration_seconds": None,
        },
    ]
    with patch("pulse_server.services.activity_service.ActivityReadRepository") as repo_cls:
        repo = repo_cls.return_value
        repo.get_workout = AsyncMock(return_value=workout)
        repo.sets_for_workout = AsyncMock(return_value=sets)
        resp = rest_client.get(f"/activity/workouts/{aid}", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    body = resp.json()
    assert body["avg_heart_rate"] == 132.0
    ex = body["exercises"][0]
    assert ex["exercise_title"] == "Bench" and ex["set_count"] == 2
    assert ex["volume_lbs"] == 135 * 8 + 145 * 6
    assert ex["top_set"]["weight_lbs"] == 145.0  # higher est-1RM
    assert body["strength_totals"]["set_count"] == 2


def test_detail_404_when_missing(rest_client) -> None:
    """An unknown workout id returns 404."""
    with patch("pulse_server.services.activity_service.ActivityReadRepository") as repo_cls:
        repo_cls.return_value.get_workout = AsyncMock(return_value=None)
        resp = rest_client.get(f"/activity/workouts/{uuid4()}", headers=AUTH_HEADERS)
    assert resp.status_code == 404
