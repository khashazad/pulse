"""Tests for the `/auth/google/*`, `/auth/whoami`, and `/auth/logout` HTTP routes.

Covers the OAuth start redirect (with the `oauth_state` cookie), all
callback error and happy paths (denied consent, missing/mismatched state,
disallowed email, token-exchange failure, missing code, success), plus
the protected `/auth/whoami` and `/auth/logout` behaviours. Builds a
TestClient with DB, USDA, and middleware patched out.
"""

from __future__ import annotations

import os
from unittest.mock import AsyncMock, patch
from urllib.parse import parse_qs, urlparse

import pytest
from fastapi.testclient import TestClient


os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "x")
os.environ.setdefault("GOOGLE_CLIENT_ID", "cid.apps.googleusercontent.com")
os.environ.setdefault("GOOGLE_CLIENT_SECRET", "secret")
os.environ.setdefault("OAUTH_REDIRECT_URI", "https://api.example.com/auth/google/callback")
os.environ.setdefault("APP_REDIRECT_SCHEME", "diettracker")
os.environ.setdefault("ALLOWED_EMAILS", "khashzd@gmail.com")
os.environ.setdefault("LEGACY_USER_KEY", "khash")
os.environ.setdefault("APP_ENV", "local")
os.environ.setdefault("SESSION_TTL_DAYS", "7")


@pytest.fixture
def client():
    """TestClient with DB pool, schema bootstrap, and USDA client mocked.

    **Outputs:**
    - TestClient: Client bound to the configured app.
    """
    with patch("diet_tracker_server.db.init_pool", new_callable=AsyncMock), \
         patch("diet_tracker_server.db.bootstrap_schema", new_callable=AsyncMock), \
         patch("diet_tracker_server.db.close_pool", new_callable=AsyncMock), \
         patch("diet_tracker_server.usda.USDAClient") as mock_usda:
        mock_usda.return_value.close = AsyncMock()
        from diet_tracker_server.config import get_settings
        get_settings.cache_clear()
        from diet_tracker_server.app import app
        with TestClient(app) as c:
            yield c


def test_start_redirects_to_google_with_state_cookie(client):
    """`/auth/google/start` 302s to Google's authorize URL and sets an HttpOnly `oauth_state` cookie."""
    r = client.get("/auth/google/start", follow_redirects=False)
    assert r.status_code == 302
    location = r.headers["location"]
    assert location.startswith("https://accounts.google.com/o/oauth2/v2/auth?")
    qs = parse_qs(urlparse(location).query)
    assert qs["client_id"] == ["cid.apps.googleusercontent.com"]
    assert qs["redirect_uri"] == ["https://api.example.com/auth/google/callback"]
    assert qs["response_type"] == ["code"]
    assert qs["state"][0]
    set_cookie = r.headers.get("set-cookie", "")
    assert "oauth_state=" in set_cookie
    assert "HttpOnly" in set_cookie
    assert "Path=/auth/google" in set_cookie


from datetime import datetime, timezone

from diet_tracker_server.auth.google import GoogleAuthError


@pytest.fixture
def _patch_db_repo():
    """Patch SessionsRepository so ``create()`` succeeds without a real DB.

    **Outputs:**
    - AsyncMock: The repo mock, with ``create`` patched to return ``None``.
    """
    fake_repo = AsyncMock()
    fake_repo.create.return_value = None
    fake_session = AsyncMock()
    fake_session_ctx = AsyncMock()
    fake_session_ctx.__aenter__.return_value = fake_session
    fake_session_ctx.__aexit__.return_value = None
    with patch("diet_tracker_server.routers.auth.get_session", return_value=fake_session_ctx), \
         patch("diet_tracker_server.routers.auth.SessionsRepository", return_value=fake_repo):
        yield fake_repo


def test_callback_google_denial_redirects_with_access_denied(client):
    """Google `error=access_denied` callback redirects back to the app with the same error."""
    r = client.get(
        "/auth/google/callback",
        params={"error": "access_denied"},
        follow_redirects=False,
    )
    assert r.status_code == 302
    assert r.headers["location"] == "diettracker://auth?error=access_denied"


def test_callback_missing_state_cookie_redirects_invalid_state(client):
    """Callback without the `oauth_state` cookie redirects with `error=invalid_state`."""
    r = client.get(
        "/auth/google/callback",
        params={"code": "x", "state": "abc"},
        follow_redirects=False,
    )
    assert r.status_code == 302
    assert "error=invalid_state" in r.headers["location"]


def test_callback_state_mismatch_redirects_invalid_state(client):
    """Callback whose `state` query doesn't match the cookie redirects with `error=invalid_state`."""
    client.cookies.set("oauth_state", "real_state", path="/auth/google")
    r = client.get(
        "/auth/google/callback",
        params={"code": "x", "state": "wrong"},
        follow_redirects=False,
    )
    assert r.status_code == 302
    assert "error=invalid_state" in r.headers["location"]


def test_callback_disallowed_email_redirects_not_allowed(client, _patch_db_repo):
    """Verified email outside `ALLOWED_EMAILS` redirects with `error=not_allowed` and skips session creation."""
    client.cookies.set("oauth_state", "s", path="/auth/google")
    with patch(
        "diet_tracker_server.routers.auth.exchange_code_for_id_token",
        new_callable=AsyncMock, return_value="jwt",
    ), patch(
        "diet_tracker_server.routers.auth.verify_id_token",
        return_value=("nobody@gmail.com", "sub"),
    ):
        r = client.get(
            "/auth/google/callback",
            params={"code": "x", "state": "s"},
            follow_redirects=False,
        )
    assert r.status_code == 302
    assert "error=not_allowed" in r.headers["location"]
    _patch_db_repo.create.assert_not_called()


def test_callback_happy_path_creates_session_and_redirects_with_token(client, _patch_db_repo):
    """Successful callback creates a session and redirects to the app scheme with `token` + `email`."""
    client.cookies.set("oauth_state", "s", path="/auth/google")
    with patch(
        "diet_tracker_server.routers.auth.exchange_code_for_id_token",
        new_callable=AsyncMock, return_value="jwt",
    ), patch(
        "diet_tracker_server.routers.auth.verify_id_token",
        return_value=("khashzd@gmail.com", "sub"),
    ):
        r = client.get(
            "/auth/google/callback",
            params={"code": "x", "state": "s"},
            follow_redirects=False,
        )
    assert r.status_code == 302
    loc = r.headers["location"]
    assert loc.startswith("diettracker://auth?")
    assert "token=" in loc
    assert "email=khashzd%40gmail.com" in loc
    _patch_db_repo.create.assert_awaited_once()


def test_callback_token_exchange_failure_redirects_server_error(client):
    """`GoogleAuthError` from token exchange redirects with `error=server_error`."""
    client.cookies.set("oauth_state", "s", path="/auth/google")
    with patch(
        "diet_tracker_server.routers.auth.exchange_code_for_id_token",
        new_callable=AsyncMock, side_effect=GoogleAuthError("boom"),
    ):
        r = client.get(
            "/auth/google/callback",
            params={"code": "x", "state": "s"},
            follow_redirects=False,
        )
    assert r.status_code == 302
    assert "error=server_error" in r.headers["location"]


def test_callback_missing_code_redirects_invalid_callback(client):
    """Callback without the `code` query param redirects with `error=invalid_callback`."""
    client.cookies.set("oauth_state", "s", path="/auth/google")
    r = client.get(
        "/auth/google/callback",
        params={"state": "s"},  # no code
        follow_redirects=False,
    )
    assert r.status_code == 302
    assert "error=invalid_callback" in r.headers["location"]


def test_whoami_unauthenticated_returns_401(client):
    """`/auth/whoami` without a Bearer token returns 401."""
    r = client.get("/auth/whoami")
    assert r.status_code == 401


def test_whoami_returns_email_and_expires_at(client):
    """`/auth/whoami` with a valid session returns the email and expiry."""
    from datetime import datetime as DT, timezone as TZ, timedelta as TD
    fut = DT.now(TZ.utc) + TD(days=7)
    fake_repo = AsyncMock()
    fake_repo.get.return_value = {"email": "khashzd@gmail.com", "expires_at": fut}
    fake_repo.slide.return_value = 1

    fake_session = AsyncMock()
    ctx = AsyncMock()
    ctx.__aenter__.return_value = fake_session
    ctx.__aexit__.return_value = None
    with patch("diet_tracker_server.auth.middleware.get_session", return_value=ctx), \
         patch("diet_tracker_server.auth.middleware.SessionsRepository", return_value=fake_repo):
        r = client.get("/auth/whoami", headers={"Authorization": "Bearer tok"})
    assert r.status_code == 200
    body = r.json()
    assert body["email"] == "khashzd@gmail.com"
    assert "expires_at" in body


def test_logout_deletes_session_and_returns_204(client):
    """`/auth/logout` deletes the session row and returns 204."""
    from datetime import datetime as DT, timezone as TZ, timedelta as TD
    fut = DT.now(TZ.utc) + TD(days=7)
    fake_repo = AsyncMock()
    fake_repo.get.return_value = {"email": "u@e.com", "expires_at": fut}
    fake_repo.slide.return_value = 1
    fake_repo.delete.return_value = 1

    fake_session = AsyncMock()
    ctx = AsyncMock()
    ctx.__aenter__.return_value = fake_session
    ctx.__aexit__.return_value = None
    with patch("diet_tracker_server.auth.middleware.get_session", return_value=ctx), \
         patch("diet_tracker_server.auth.middleware.SessionsRepository", return_value=fake_repo), \
         patch("diet_tracker_server.routers.auth.get_session", return_value=ctx), \
         patch("diet_tracker_server.routers.auth.SessionsRepository", return_value=fake_repo):
        r = client.post("/auth/logout", headers={"Authorization": "Bearer tok"})
    assert r.status_code == 204
    fake_repo.delete.assert_awaited()
