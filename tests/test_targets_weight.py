"""HTTP tests for the `target_weight_lb` field on `/targets`.

Covers GET/PUT round-tripping of `target_weight_lb`, including the
null-permitted GET response. Uses a TestClient with DB and auth
middleware mocked.
"""

from __future__ import annotations

import os
from datetime import datetime as DateTimeValue
from datetime import timedelta as TimeDeltaValue
from datetime import timezone as TimezoneValue
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test")


def _now() -> DateTimeValue:
    """Return the current UTC timestamp.

    **Outputs:**
    - datetime: Aware ``datetime`` in UTC.
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
            """Yield a `MagicMock` DB session with a working async `begin()` ctx."""
            session = MagicMock()
            session.begin = MagicMock()
            session.begin.return_value.__aenter__ = AsyncMock(return_value=session)
            session.begin.return_value.__aexit__ = AsyncMock(return_value=False)
            yield session

        app.dependency_overrides[get_session_dependency] = _fake_session_dep
        try:
            with TestClient(app) as test_client:
                yield test_client
        finally:
            app.dependency_overrides.pop(get_session_dependency, None)


HEADERS = {"Authorization": "Bearer tok"}


def test_get_targets_includes_target_weight(client: TestClient) -> None:
    """`GET /targets` exposes `target_weight_lb` in the response payload."""
    with patch(
        "diet_tracker_server.routers.targets.TargetsRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.get_target_profile = AsyncMock(
            return_value={
                "calories_target": 2000,
                "protein_g_target": 150.0,
                "carbs_g_target": 200.0,
                "fat_g_target": 70.0,
                "target_weight_lb": 175.0,
            }
        )
        resp = client.get("/targets", headers=HEADERS)
    assert resp.status_code == 200
    assert resp.json()["target_weight_lb"] == 175.0


def test_get_targets_null_target_weight(client: TestClient) -> None:
    """`GET /targets` returns `target_weight_lb=null` when unset in the DB."""
    with patch(
        "diet_tracker_server.routers.targets.TargetsRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.get_target_profile = AsyncMock(
            return_value={
                "calories_target": 2000,
                "protein_g_target": 150.0,
                "carbs_g_target": 200.0,
                "fat_g_target": 70.0,
                "target_weight_lb": None,
            }
        )
        resp = client.get("/targets", headers=HEADERS)
    assert resp.status_code == 200
    assert resp.json()["target_weight_lb"] is None


def test_put_targets_writes_target_weight(client: TestClient) -> None:
    """`PUT /targets` forwards `target_weight_lb` to the repository upsert."""
    with patch(
        "diet_tracker_server.routers.targets.TargetsRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.upsert_targets = AsyncMock(return_value=None)
        resp = client.put(
            "/targets",
            headers=HEADERS,
            json={
                "calories": 2000,
                "protein_g": 150.0,
                "carbs_g": 200.0,
                "fat_g": 70.0,
                "target_weight_lb": 165.5,
            },
        )
    assert resp.status_code == 200
    instance.upsert_targets.assert_awaited_once()
    kwargs = instance.upsert_targets.await_args.kwargs
    assert kwargs["target_weight_lb"] == 165.5
