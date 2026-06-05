"""Smoke tests for the FastAPI app's middleware-gated entry points.

Covers the health endpoint pass-through and unauthenticated rejection on
protected routes. Exercises the module-level app wiring via a TestClient
with the DB pool and USDA client patched out so no real I/O occurs.
"""

from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client() -> TestClient:
    """TestClient with DB pool, schema bootstrap, and USDA client mocked.

    **Outputs:**
    - TestClient: Client bound to the app under test.
    """
    with (
        patch("pulse_server.db.init_pool", new_callable=AsyncMock),
        patch("pulse_server.db.bootstrap_schema", new_callable=AsyncMock),
        patch("pulse_server.db.close_pool", new_callable=AsyncMock),
        patch("pulse_server.usda.USDAClient") as mock_usda_client,
    ):
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
