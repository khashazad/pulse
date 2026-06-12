"""Behaviour tests for `SessionAuthMiddleware`.

Builds a minimal FastAPI app to exercise the middleware stack in isolation:
unauthenticated pass-through on `/health`, 401 responses for missing/
malformed/expired/unknown Bearer tokens, happy-path session slide +
`request.state` attachment, and exemption paths for the MCP and OAuth
metadata routes.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock, patch

import pytest
from fastapi import Depends, FastAPI, Request
from fastapi.testclient import TestClient


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    """Populate every env var required by `Settings` for this module's tests.

    **Inputs:**
    - monkeypatch (pytest.MonkeyPatch): Used to set env vars and reset the settings cache.
    """
    monkeypatch.setenv("DATABASE_URL", "postgresql://localhost/test")
    monkeypatch.setenv("USDA_API_KEY", "x")
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "cid")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "secret")
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "https://api.example.com/auth/google/callback")
    monkeypatch.setenv("APP_REDIRECT_SCHEME", "diettracker")
    monkeypatch.setenv("ALLOWED_EMAILS", "khashzd@gmail.com")
    monkeypatch.setenv("LEGACY_USER_KEY", "khash")
    monkeypatch.setenv("APP_ENV", "local")
    monkeypatch.setenv("SESSION_TTL_DAYS", "7")
    from pulse_server.config import get_settings

    get_settings.cache_clear()


def _build_app():
    """Construct a tiny FastAPI app wired with the production auth middleware.

    **Outputs:**
    - FastAPI: App exposing ``/health`` (public) and ``/me`` (session-required).
    """
    from pulse_server.auth.middleware import (
        SessionAuthMiddleware,
        require_session,
    )

    app = FastAPI()
    app.add_middleware(SessionAuthMiddleware)

    @app.get("/health")
    async def health():
        return {"status": "ok"}

    @app.get("/me")
    async def me(request: Request, _: None = Depends(require_session)):
        return {"email": request.state.email, "user_key": request.state.user_key}

    return app


def _patched_session_repo(*, get_return, slide_return=1, delete_return=1):
    """Build an AsyncMock `SessionsRepository` and matching async-context session.

    **Inputs:**
    - get_return (Any): Value returned by ``repo.get`` — usually a dict row or ``None``.
    - slide_return (int): Rows affected by ``slide`` (default ``1``).
    - delete_return (int): Rows affected by ``delete`` (default ``1``).

    **Outputs:**
    - tuple[AsyncMock, AsyncMock]: ``(repo, ctx)`` ready for patching the
      middleware's ``SessionsRepository`` and ``get_session`` references.
    """
    repo = AsyncMock()
    repo.get.return_value = get_return
    repo.slide.return_value = slide_return
    repo.delete.return_value = delete_return
    fake_session = AsyncMock()
    ctx = AsyncMock()
    ctx.__aenter__.return_value = fake_session
    ctx.__aexit__.return_value = None
    return repo, ctx


def test_health_unauthenticated_passes_through():
    """`/health` returns 200 with no Bearer header attached."""
    app = _build_app()
    with TestClient(app) as c:
        r = c.get("/health")
    assert r.status_code == 200


def test_protected_missing_bearer_returns_401():
    """Protected `/me` returns 401 when no Authorization header is provided."""
    app = _build_app()
    with TestClient(app) as c:
        r = c.get("/me")
    assert r.status_code == 401


def test_protected_invalid_bearer_format_returns_401():
    """Non-Bearer Authorization schemes are rejected with 401."""
    app = _build_app()
    with TestClient(app) as c:
        r = c.get("/me", headers={"Authorization": "Token abc"})
    assert r.status_code == 401


def test_protected_unknown_session_returns_401():
    """Bearer token that doesn't match any stored session returns 401."""
    app = _build_app()
    repo, ctx = _patched_session_repo(get_return=None)
    with (
        patch("pulse_server.auth.middleware.get_session", return_value=ctx),
        patch("pulse_server.auth.middleware.SessionsRepository", return_value=repo),
    ):
        with TestClient(app) as c:
            r = c.get("/me", headers={"Authorization": "Bearer unknown"})
    assert r.status_code == 401


def test_protected_expired_session_returns_401_and_deletes():
    """Expired session returns 401 and triggers deletion of the stale row."""
    app = _build_app()
    past = datetime.now(UTC) - timedelta(days=1)
    repo, ctx = _patched_session_repo(get_return={"email": "u@e.com", "expires_at": past})
    with (
        patch("pulse_server.auth.middleware.get_session", return_value=ctx),
        patch("pulse_server.auth.middleware.SessionsRepository", return_value=repo),
    ):
        with TestClient(app) as c:
            r = c.get("/me", headers={"Authorization": "Bearer tok"})
    assert r.status_code == 401
    repo.delete.assert_awaited_once()


def test_protected_happy_path_slides_and_attaches_state():
    """A session past half its TTL slides expiry and attaches state.

    TTL is 7 days here (module env fixture), so the slide threshold is 3.5
    days of remaining life; a session expiring in 2 days is due for a slide.
    """
    app = _build_app()
    future = datetime.now(UTC) + timedelta(days=2)
    repo, ctx = _patched_session_repo(
        get_return={"email": "khashzd@gmail.com", "expires_at": future}
    )
    with (
        patch("pulse_server.auth.middleware.get_session", return_value=ctx),
        patch("pulse_server.auth.middleware.SessionsRepository", return_value=repo),
    ):
        with TestClient(app) as c:
            r = c.get("/me", headers={"Authorization": "Bearer tok"})
    assert r.status_code == 200
    assert r.json() == {"email": "khashzd@gmail.com", "user_key": "khash"}
    repo.slide.assert_awaited_once()


def test_protected_fresh_session_skips_slide():
    """A session with more than half its TTL remaining authenticates without an UPDATE.

    TTL is 7 days here; a session expiring in 6 days is above the 3.5-day
    threshold, so the middleware must not issue the slide write.
    """
    app = _build_app()
    future = datetime.now(UTC) + timedelta(days=6)
    repo, ctx = _patched_session_repo(
        get_return={"email": "khashzd@gmail.com", "expires_at": future}
    )
    with (
        patch("pulse_server.auth.middleware.get_session", return_value=ctx),
        patch("pulse_server.auth.middleware.SessionsRepository", return_value=repo),
    ):
        with TestClient(app) as c:
            r = c.get("/me", headers={"Authorization": "Bearer tok"})
    assert r.status_code == 200
    assert r.json() == {"email": "khashzd@gmail.com", "user_key": "khash"}
    repo.slide.assert_not_awaited()


def _build_app_with_mcp_exemptions():
    """Build a FastAPI app whose middleware exempts `/mcp/*` and OAuth metadata paths.

    **Outputs:**
    - FastAPI: App with ``/mcp/probe``, ``/authorize``, and
      ``/.well-known/oauth-authorization-server`` routes registered.
    """
    from pulse_server.auth.middleware import SessionAuthMiddleware

    app = FastAPI()
    app.add_middleware(
        SessionAuthMiddleware,
        exempt_paths=frozenset({"/authorize", "/token", "/.well-known/oauth-authorization-server"}),
        exempt_prefixes=("/mcp",),
    )

    @app.get("/mcp/probe")
    async def mcp_probe():
        return {"ok": True}

    @app.get("/authorize")
    async def authorize():
        return {"ok": True}

    @app.get("/.well-known/oauth-authorization-server")
    async def metadata():
        return {"ok": True}

    return app


def test_mcp_prefix_bypasses_session_auth():
    """Requests under `/mcp/*` skip session auth and return 200 without a Bearer token."""
    app = _build_app_with_mcp_exemptions()
    with TestClient(app) as c:
        r = c.get("/mcp/probe")  # no Bearer header
    assert r.status_code == 200


def test_oauth_metadata_bypasses_session_auth():
    """Exempt OAuth metadata routes return 200 without a Bearer token."""
    app = _build_app_with_mcp_exemptions()
    with TestClient(app) as c:
        r1 = c.get("/authorize")
        r2 = c.get("/.well-known/oauth-authorization-server")
    assert r1.status_code == 200
    assert r2.status_code == 200
