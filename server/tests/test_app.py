"""Smoke tests for the FastAPI app's middleware-gated entry points.

Covers the health endpoint pass-through and unauthenticated rejection on
protected routes. Exercises the module-level app wiring via a TestClient
with the DB pool and USDA client patched out so no real I/O occurs.
"""

from unittest.mock import AsyncMock, patch

import pytest
from fastapi import FastAPI
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


def test_mcp_initialize_does_not_redirect(client: TestClient) -> None:
    """The canonical MCP URL handles initialization without a slash redirect."""
    response = client.post(
        "/mcp",
        headers={"Accept": "application/json, text/event-stream"},
        json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "test-client", "version": "1.0"},
            },
        },
        follow_redirects=False,
    )

    assert response.status_code == 200
    assert response.headers.get("location") is None
    assert '"protocolVersion":"2025-06-18"' in response.text


def test_web_root_is_public_when_build_is_absent(client: TestClient) -> None:
    """The public SPA entry route reaches static delivery instead of session auth."""
    response = client.get("/")
    assert response.status_code == 404
    assert response.json()["detail"] == "Web client is not built"


@pytest.fixture
def built_web_client(tmp_path) -> TestClient:
    """Create an isolated web router backed by a minimal temporary Vite build.

    **Inputs:**
    - tmp_path (Path): Pytest-managed directory used as the build root.

    **Outputs:**
    - TestClient: Client serving the temporary index and fingerprinted asset.
    """
    (tmp_path / "assets").mkdir()
    (tmp_path / "index.html").write_text("<main>Pulse web</main>")
    (tmp_path / "assets" / "app-abc123.js").write_text("window.PULSE = true")
    app = FastAPI()

    from pulse_server.web import create_web_router

    app.include_router(create_web_router(tmp_path))
    return TestClient(app)


def test_web_router_serves_index(built_web_client: TestClient) -> None:
    """The root route serves the compiled SPA entry document."""
    response = built_web_client.get("/")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    assert "Pulse web" in response.text


def test_web_router_serves_login_callback_history_fallback(
    built_web_client: TestClient,
) -> None:
    """Direct navigation to the OAuth callback route returns the SPA entry document."""
    response = built_web_client.get("/login/callback")
    assert response.status_code == 200
    assert "Pulse web" in response.text


def test_web_router_serves_fingerprinted_asset(built_web_client: TestClient) -> None:
    """Vite assets are served with their inferred content type and immutable caching."""
    response = built_web_client.get("/assets/app-abc123.js")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/javascript")
    assert response.headers["cache-control"] == "public, max-age=31536000, immutable"
    assert response.text == "window.PULSE = true"


def test_web_router_returns_404_for_missing_asset(built_web_client: TestClient) -> None:
    """A missing client asset returns 404 rather than the SPA document."""
    response = built_web_client.get("/assets/missing.js")
    assert response.status_code == 404
    assert response.json()["detail"] == "Web asset not found"
