"""HTTP tests for GET /activity/week using the shared mocked-DB fixture."""

from __future__ import annotations

from datetime import UTC, date, datetime
from unittest.mock import AsyncMock, patch
from uuid import uuid4

AUTH_HEADERS = {"Authorization": "Bearer tok"}  # mirrors conftest.AUTH_HEADERS


def test_week_returns_day_groups_with_strength_briefs(rest_client) -> None:
    """The endpoint groups workouts by local_date, newest day first, enriching strength rows."""
    aid1 = uuid4()
    sw1 = uuid4()
    aid2 = uuid4()
    rows = [
        {
            "id": aid1,
            "activity_type": "TraditionalStrengthTraining",
            "start_time": datetime(2026, 6, 23, 18, 0, tzinfo=UTC),
            "end_time": datetime(2026, 6, 23, 18, 57, tzinfo=UTC),
            "duration_min": 57,
            "active_energy_cal": 276,
            "distance_km": None,
            "linked_strength_workout_id": sw1,
            "local_date": date(2026, 6, 23),
        },
        {
            "id": aid2,
            "activity_type": "Running",
            "start_time": datetime(2026, 6, 24, 7, 0, tzinfo=UTC),
            "end_time": datetime(2026, 6, 24, 7, 30, tzinfo=UTC),
            "duration_min": 30,
            "active_energy_cal": 300,
            "distance_km": 5.0,
            "linked_strength_workout_id": None,
            "local_date": date(2026, 6, 24),
        },
    ]
    with patch("pulse_server.services.activity_service.ActivityReadRepository") as repo_cls:
        repo = repo_cls.return_value
        repo.workouts_in_range = AsyncMock(return_value=rows)
        repo.strength_briefs = AsyncMock(
            return_value={sw1: {"exercise_count": 4, "set_count": 16, "volume_lbs": 8000.0}}
        )
        resp = rest_client.get("/activity/week?anchor=2026-06-22", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    body = resp.json()
    # week containing Mon 2026-06-22 runs Jun 22 - Jun 28
    assert body["week_start"] == "2026-06-22"
    assert body["week_end"] == "2026-06-28"
    groups = body["day_groups"]
    # only days with workouts; newest day first
    assert len(groups) == 2
    assert groups[0]["date"] == "2026-06-24"
    assert groups[1]["date"] == "2026-06-23"
    # running on June 24
    run = groups[0]["workouts"][0]
    assert run["activity_type"] == "Running"
    assert run["has_strength_detail"] is False
    assert run["strength_brief"] is None
    # strength on June 23 — enriched
    strength = groups[1]["workouts"][0]
    assert strength["activity_type"] == "TraditionalStrengthTraining"
    assert strength["has_strength_detail"] is True
    assert strength["strength_brief"]["set_count"] == 16
    assert strength["strength_brief"]["exercise_count"] == 4


def test_week_requires_auth(rest_client) -> None:
    """Without a bearer token the endpoint returns 401."""
    assert rest_client.get("/activity/week").status_code == 401


def test_week_multiple_workouts_same_day_newest_first(rest_client) -> None:
    """Multiple workouts on the same day are ordered newest-first within the DayGroup."""
    aid1 = uuid4()
    aid2 = uuid4()
    rows = [
        {
            "id": aid1,
            "activity_type": "Running",
            "start_time": datetime(2026, 6, 23, 8, 0, tzinfo=UTC),
            "end_time": datetime(2026, 6, 23, 8, 30, tzinfo=UTC),
            "duration_min": 30,
            "active_energy_cal": 300,
            "distance_km": 5.0,
            "linked_strength_workout_id": None,
            "local_date": date(2026, 6, 23),
        },
        {
            "id": aid2,
            "activity_type": "Cycling",
            "start_time": datetime(2026, 6, 23, 17, 0, tzinfo=UTC),
            "end_time": datetime(2026, 6, 23, 18, 0, tzinfo=UTC),
            "duration_min": 60,
            "active_energy_cal": 400,
            "distance_km": 20.0,
            "linked_strength_workout_id": None,
            "local_date": date(2026, 6, 23),
        },
    ]
    with patch("pulse_server.services.activity_service.ActivityReadRepository") as repo_cls:
        repo = repo_cls.return_value
        repo.workouts_in_range = AsyncMock(return_value=rows)
        repo.strength_briefs = AsyncMock(return_value={})
        resp = rest_client.get("/activity/week?anchor=2026-06-23", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    body = resp.json()
    groups = body["day_groups"]
    assert len(groups) == 1
    workouts = groups[0]["workouts"]
    assert len(workouts) == 2
    # Cycling (17:00) is newer than Running (08:00) — newest first
    assert workouts[0]["activity_type"] == "Cycling"
    assert workouts[1]["activity_type"] == "Running"


def test_week_empty_returns_no_day_groups(rest_client) -> None:
    """A week with no workouts returns week bounds but an empty day_groups list."""
    with patch("pulse_server.services.activity_service.ActivityReadRepository") as repo_cls:
        repo = repo_cls.return_value
        repo.workouts_in_range = AsyncMock(return_value=[])
        repo.strength_briefs = AsyncMock(return_value={})
        resp = rest_client.get("/activity/week?anchor=2026-06-22", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    body = resp.json()
    assert body["week_start"] == "2026-06-22"
    assert body["week_end"] == "2026-06-28"
    assert body["day_groups"] == []
