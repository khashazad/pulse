"""HTTP test for GET /activity/workouts using the shared mocked-DB fixture."""

from __future__ import annotations

from datetime import UTC, datetime
from unittest.mock import AsyncMock, patch
from uuid import uuid4

AUTH_HEADERS = {"Authorization": "Bearer tok"}  # mirrors conftest.AUTH_HEADERS


def test_feed_returns_items_and_cursor(rest_client) -> None:
    """The endpoint maps repository rows into summaries and exposes next_before."""
    wid = uuid4()
    sw = uuid4()
    rows = [
        {
            "id": wid,
            "activity_type": "TraditionalStrengthTraining",
            "start_time": datetime(2026, 6, 24, 18, 0, tzinfo=UTC),
            "end_time": datetime(2026, 6, 24, 18, 57, tzinfo=UTC),
            "duration_min": 57,
            "active_energy_cal": 276,
            "distance_km": None,
            "linked_strength_workout_id": sw,
        }
    ]
    with (
        patch("pulse_server.services.activity_service.ActivityReadRepository") as repo_cls,
    ):
        repo = repo_cls.return_value
        repo.list_workouts = AsyncMock(return_value=rows)
        repo.strength_briefs = AsyncMock(
            return_value={sw: {"exercise_count": 5, "set_count": 18, "volume_lbs": 9240.0}}
        )
        resp = rest_client.get("/activity/workouts?limit=1", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    body = resp.json()
    item = body["items"][0]
    assert item["has_strength_detail"] is True
    assert item["strength_brief"]["set_count"] == 18
    assert body["next_before"] == "2026-06-24T18:00:00Z"


def test_feed_requires_auth(rest_client) -> None:
    """Without a bearer token the endpoint returns 401."""
    assert rest_client.get("/activity/workouts").status_code == 401
