from __future__ import annotations

from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, patch

import pytest
from fastapi import Depends, FastAPI, Request
from fastapi.testclient import TestClient


@pytest.fixture(autouse=True)
def _env(monkeypatch):
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
    from diet_tracker_server.config import get_settings

    get_settings.cache_clear()


def _build_app():
    from diet_tracker_server.auth.middleware import (
        SessionAuthMiddleware,
        UserKeyGuardrailMiddleware,
        require_session,
    )

    app = FastAPI()
    app.add_middleware(SessionAuthMiddleware)
    app.add_middleware(UserKeyGuardrailMiddleware)

    @app.get("/health")
    async def health():
        return {"status": "ok"}

    @app.get("/me")
    async def me(request: Request, _: None = Depends(require_session)):
        return {"email": request.state.email, "user_key": request.state.user_key}

    return app


def _patched_session_repo(*, get_return, slide_return=1, delete_return=1):
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
    app = _build_app()
    with TestClient(app) as c:
        r = c.get("/health")
    assert r.status_code == 200


def test_protected_missing_bearer_returns_401():
    app = _build_app()
    with TestClient(app) as c:
        r = c.get("/me")
    assert r.status_code == 401


def test_protected_invalid_bearer_format_returns_401():
    app = _build_app()
    with TestClient(app) as c:
        r = c.get("/me", headers={"Authorization": "Token abc"})
    assert r.status_code == 401


def test_protected_unknown_session_returns_401():
    app = _build_app()
    repo, ctx = _patched_session_repo(get_return=None)
    with patch("diet_tracker_server.auth.middleware.get_session", return_value=ctx), \
         patch("diet_tracker_server.auth.middleware.SessionsRepository", return_value=repo):
        with TestClient(app) as c:
            r = c.get("/me", headers={"Authorization": "Bearer unknown"})
    assert r.status_code == 401


def test_protected_expired_session_returns_401_and_deletes():
    app = _build_app()
    past = datetime.now(timezone.utc) - timedelta(days=1)
    repo, ctx = _patched_session_repo(get_return={"email": "u@e.com", "expires_at": past})
    with patch("diet_tracker_server.auth.middleware.get_session", return_value=ctx), \
         patch("diet_tracker_server.auth.middleware.SessionsRepository", return_value=repo):
        with TestClient(app) as c:
            r = c.get("/me", headers={"Authorization": "Bearer tok"})
    assert r.status_code == 401
    repo.delete.assert_awaited_once()


def test_protected_happy_path_slides_and_attaches_state():
    app = _build_app()
    future = datetime.now(timezone.utc) + timedelta(days=7)
    repo, ctx = _patched_session_repo(get_return={"email": "khashzd@gmail.com", "expires_at": future})
    with patch("diet_tracker_server.auth.middleware.get_session", return_value=ctx), \
         patch("diet_tracker_server.auth.middleware.SessionsRepository", return_value=repo):
        with TestClient(app) as c:
            r = c.get("/me", headers={"Authorization": "Bearer tok"})
    assert r.status_code == 200
    assert r.json() == {"email": "khashzd@gmail.com", "user_key": "khash"}
    repo.slide.assert_awaited_once()


def test_user_key_query_guardrail_returns_400_on_protected_route():
    app = _build_app()
    with TestClient(app) as c:
        r = c.get("/me?user_key=foo")
    # Guardrail runs before auth, so 400 (not 401), even with no Bearer header.
    assert r.status_code == 400
    assert "user_key" in (r.json().get("error") or "")


def test_user_key_query_guardrail_skips_health_and_auth_routes():
    app = _build_app()
    with TestClient(app) as c:
        r1 = c.get("/health?user_key=foo")
        # /auth/* not registered on this dummy app — should 404, not 400.
        r2 = c.get("/auth/google/start?user_key=foo")
    assert r1.status_code == 200
    assert r2.status_code != 400


def _build_app_with_mcp_exemptions():
    from diet_tracker_server.auth.middleware import (
        SessionAuthMiddleware,
        UserKeyGuardrailMiddleware,
    )

    app = FastAPI()
    app.add_middleware(
        SessionAuthMiddleware,
        exempt_paths=frozenset({"/authorize", "/token", "/.well-known/oauth-authorization-server"}),
        exempt_prefixes=("/mcp",),
    )
    app.add_middleware(
        UserKeyGuardrailMiddleware,
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
    app = _build_app_with_mcp_exemptions()
    with TestClient(app) as c:
        r = c.get("/mcp/probe")  # no Bearer header
    assert r.status_code == 200


def test_oauth_metadata_bypasses_session_auth():
    app = _build_app_with_mcp_exemptions()
    with TestClient(app) as c:
        r1 = c.get("/authorize")
        r2 = c.get("/.well-known/oauth-authorization-server")
    assert r1.status_code == 200
    assert r2.status_code == 200
