"""Smoke tests for the FastAPI app's middleware-gated entry points.

Covers the health endpoint pass-through, unauthenticated rejection on
protected routes, and the `user_key` query guardrail. Exercises the app
factory wiring via a TestClient with the DB pool and USDA client patched
out so no real I/O occurs.
"""

from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient


def _patched_session_repo(email: str = "khashzd@gmail.com") -> tuple[AsyncMock, AsyncMock]:
    """Build an AsyncMock SessionsRepository + async-context pair for middleware short-circuiting.

    **Inputs:**
    - email (str): Email value the fake session row reports.

    **Outputs:**
    - tuple[AsyncMock, AsyncMock]: ``(repo, ctx)`` suitable for patching
      ``SessionsRepository`` and ``get_session`` respectively.
    """
    fut = datetime.now(timezone.utc) + timedelta(days=7)
    repo = AsyncMock()
    repo.get.return_value = {"email": email, "expires_at": fut}
    repo.slide.return_value = 1
    repo.delete.return_value = 1
    fake_session = AsyncMock()
    ctx = AsyncMock()
    ctx.__aenter__.return_value = fake_session
    ctx.__aexit__.return_value = None
    return repo, ctx


@pytest.fixture
def client() -> TestClient:
    """TestClient with DB pool, schema bootstrap, and USDA client mocked.

    **Outputs:**
    - TestClient: Client bound to the app under test.
    """
    with patch("pulse_server.db.init_pool", new_callable=AsyncMock), patch(
        "pulse_server.db.bootstrap_schema", new_callable=AsyncMock
    ), patch("pulse_server.db.close_pool", new_callable=AsyncMock), patch(
        "pulse_server.usda.USDAClient"
    ) as mock_usda_client:
        mock_usda_client.return_value.close = AsyncMock()
        from pulse_server.app import app

        with TestClient(app) as test_client:
            yield test_client


def test_health_check(client: TestClient) -> None:
    """Health endpoint responds 200 with ``status=ok``."""
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_unauthenticated_request_rejected(client: TestClient) -> None:
    """Protected route without a Bearer token returns 401."""
    response = client.get("/entries", params={"date": "2026-04-05"})
    assert response.status_code == 401


def test_user_key_query_rejected_on_protected_route(client: TestClient) -> None:
    """`user_key` query on a protected route returns 400 even with a valid Bearer token."""
    repo, ctx = _patched_session_repo()
    with patch("pulse_server.auth.middleware.get_session", return_value=ctx), patch(
        "pulse_server.auth.middleware.SessionsRepository", return_value=repo
    ):
        response = client.get(
            "/entries?user_key=foo&date=2026-04-05",
            headers={"Authorization": "Bearer tok"},
        )
    assert response.status_code == 400
    assert "user_key" in (response.json().get("error") or "")
