"""HTTP tests for GET /activity/types and PUT /activity/types/{activity_type}.

Mirrors the mocked-DB fixture style of test_activity_feed_api.py /
test_activity_summary_api.py: both repository calls are patched at the
ActivityReadRepository class, keeping the test layer purely in-process.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, patch

AUTH_HEADERS = {"Authorization": "Bearer tok"}  # mirrors conftest.AUTH_HEADERS


def test_list_types_returns_200_with_effective_cardio_flags(rest_client) -> None:
    """GET /activity/types returns 200 with each type's effective is_cardio flag.

    Running is in DEFAULT_CARDIO_TYPES so it comes back True;
    TraditionalStrengthTraining is not so it comes back False when no override is set.
    """
    with patch("pulse_server.services.activity_service.ActivityReadRepository") as repo_cls:
        repo = repo_cls.return_value
        repo.distinct_activity_types = AsyncMock(
            return_value=[
                {"activity_type": "Running", "count": 10},
                {"activity_type": "TraditionalStrengthTraining", "count": 5},
            ]
        )
        repo.cardio_overrides = AsyncMock(return_value={})
        resp = rest_client.get("/activity/types", headers=AUTH_HEADERS)

    assert resp.status_code == 200
    body = resp.json()
    types = {t["activity_type"]: t for t in body["types"]}

    assert "Running" in types
    assert types["Running"]["is_cardio"] is True
    assert types["Running"]["display_name"] == "Running"
    assert types["Running"]["count"] == 10

    assert "TraditionalStrengthTraining" in types
    assert types["TraditionalStrengthTraining"]["is_cardio"] is False
    assert types["TraditionalStrengthTraining"]["display_name"] == "Traditional Strength Training"
    assert types["TraditionalStrengthTraining"]["count"] == 5


def test_list_types_respects_cardio_override(rest_client) -> None:
    """GET /activity/types honours an override that flips a default-cardio type to False."""
    with patch("pulse_server.services.activity_service.ActivityReadRepository") as repo_cls:
        repo = repo_cls.return_value
        repo.distinct_activity_types = AsyncMock(
            return_value=[{"activity_type": "Running", "count": 3}]
        )
        repo.cardio_overrides = AsyncMock(return_value={"Running": False})
        resp = rest_client.get("/activity/types", headers=AUTH_HEADERS)

    assert resp.status_code == 200
    body = resp.json()
    assert body["types"][0]["is_cardio"] is False


def test_list_types_sorted_count_desc(rest_client) -> None:
    """GET /activity/types returns types in descending count order."""
    with patch("pulse_server.services.activity_service.ActivityReadRepository") as repo_cls:
        repo = repo_cls.return_value
        repo.distinct_activity_types = AsyncMock(
            return_value=[
                {"activity_type": "Running", "count": 10},
                {"activity_type": "Cycling", "count": 2},
            ]
        )
        repo.cardio_overrides = AsyncMock(return_value={})
        resp = rest_client.get("/activity/types", headers=AUTH_HEADERS)

    assert resp.status_code == 200
    counts = [t["count"] for t in resp.json()["types"]]
    assert counts == sorted(counts, reverse=True)


def test_list_types_requires_auth(rest_client) -> None:
    """GET /activity/types returns 401 without a bearer token."""
    assert rest_client.get("/activity/types").status_code == 401


def test_put_type_flips_cardio_flag(rest_client) -> None:
    """PUT /activity/types/{type} sets the override and returns the updated setting."""
    with patch("pulse_server.services.activity_service.ActivityReadRepository") as repo_cls:
        repo = repo_cls.return_value
        repo.distinct_activity_types = AsyncMock(
            return_value=[{"activity_type": "Running", "count": 7}]
        )
        repo.set_cardio_override = AsyncMock(return_value=None)
        resp = rest_client.put(
            "/activity/types/Running",
            json={"is_cardio": False},
            headers=AUTH_HEADERS,
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["activity_type"] == "Running"
    assert body["is_cardio"] is False
    assert body["count"] == 7
    assert body["display_name"] == "Running"


def test_put_type_unknown_returns_404(rest_client) -> None:
    """PUT /activity/types/{type} returns 404 when the type has no workouts for the user."""
    with patch("pulse_server.services.activity_service.ActivityReadRepository") as repo_cls:
        repo = repo_cls.return_value
        repo.distinct_activity_types = AsyncMock(return_value=[])
        repo.set_cardio_override = AsyncMock(return_value=None)
        resp = rest_client.put(
            "/activity/types/NonsenseType",
            json={"is_cardio": True},
            headers=AUTH_HEADERS,
        )

    assert resp.status_code == 404


def test_put_type_requires_auth(rest_client) -> None:
    """PUT /activity/types/{type} returns 401 without a bearer token."""
    assert rest_client.put("/activity/types/Running", json={"is_cardio": True}).status_code == 401
