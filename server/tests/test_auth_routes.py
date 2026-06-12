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


@pytest.fixture(autouse=True)
def _reset_auth_rate_limiter():
    """Give every test a fresh auth rate-limit budget.

    The limiter is module-level state keyed by client IP, and every TestClient
    request shares the same synthetic ``testclient`` address — without a reset,
    earlier tests would eat into a later test's budget.

    **Outputs:**
    - None: Yields control to the test, resetting before and after.
    """
    from pulse_server.routers.auth import _auth_rate_limiter

    _auth_rate_limiter.reset()
    yield
    _auth_rate_limiter.reset()


@pytest.fixture
def client():
    """TestClient with DB pool, schema bootstrap, and USDA client mocked.

    **Outputs:**
    - TestClient: Client bound to the configured app.
    """
    with (
        patch("pulse_server.db.init_pool", new_callable=AsyncMock),
        patch("pulse_server.db.bootstrap_schema", new_callable=AsyncMock),
        patch("pulse_server.db.close_pool", new_callable=AsyncMock),
        patch("pulse_server.usda.USDAClient") as mock_usda,
    ):
        mock_usda.return_value.close = AsyncMock()
        from pulse_server.config import get_settings

        get_settings.cache_clear()
        from pulse_server.app import app

        with TestClient(app) as c:
            yield c


def test_start_redirects_to_google_with_state_cookie(client):
    """`/auth/google/start` with a PKCE challenge 302s to Google and sets HttpOnly state + pkce cookies."""
    r = client.get(
        "/auth/google/start",
        params={"code_challenge": "abc123challenge", "code_challenge_method": "S256"},
        follow_redirects=False,
    )
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
    assert "oauth_pkce=" in set_cookie
    assert "HttpOnly" in set_cookie
    assert "Path=/auth/google" in set_cookie


def test_start_without_pkce_challenge_redirects_invalid_request(client):
    """`/auth/google/start` without a PKCE challenge aborts back to the app with `invalid_request`."""
    r = client.get("/auth/google/start", follow_redirects=False)
    assert r.status_code == 302
    assert r.headers["location"] == "diettracker://auth?error=invalid_request"


def test_start_rate_limited_after_budget_exhausted(client):
    """`/auth/google/start` returns 429 with Retry-After once the per-IP budget is spent."""
    from pulse_server.routers.auth import AUTH_RATE_LIMIT_MAX_REQUESTS

    for _ in range(AUTH_RATE_LIMIT_MAX_REQUESTS):
        r = client.get(
            "/auth/google/start",
            params={"code_challenge": "abc123challenge", "code_challenge_method": "S256"},
            follow_redirects=False,
        )
        assert r.status_code == 302
    r = client.get(
        "/auth/google/start",
        params={"code_challenge": "abc123challenge", "code_challenge_method": "S256"},
        follow_redirects=False,
    )
    assert r.status_code == 429
    assert "retry-after" in {k.lower() for k in r.headers}


def test_rate_limit_keys_on_rightmost_xff_entry(client):
    """Spoofed leftmost X-Forwarded-For values cannot mint fresh rate-limit buckets.

    The client controls every prepended entry; only the rightmost is appended
    by the trusted edge proxy. Rotating leftmost values with a fixed rightmost
    entry must all land in one bucket and trip the limit.
    """
    from pulse_server.routers.auth import AUTH_RATE_LIMIT_MAX_REQUESTS

    last = None
    for i in range(AUTH_RATE_LIMIT_MAX_REQUESTS + 1):
        last = client.get(
            "/auth/google/start",
            params={"code_challenge": "abc123challenge", "code_challenge_method": "S256"},
            headers={"X-Forwarded-For": f"10.0.0.{i}, 203.0.113.7"},
            follow_redirects=False,
        )
    assert last is not None
    assert last.status_code == 429


def test_exchange_rate_limited_after_budget_exhausted(client):
    """`/auth/google/exchange` returns 429 once the per-IP budget is spent.

    Bodies are syntactically valid but the budget is exhausted before any code
    lookup happens, so no DB patching is needed: the 429 fires first.
    """
    from pulse_server.routers.auth import _auth_rate_limiter

    # Exhaust the budget directly (cheaper than 30 HTTP round-trips) for the
    # IP TestClient reports for every request.
    for _ in range(1000):
        if not _auth_rate_limiter.allow("testclient"):
            break
    body = {"code": "x" * 32, "code_verifier": "v" * 43}
    r = client.post("/auth/google/exchange", json=body)
    assert r.status_code == 429


from datetime import UTC

from pulse_server.auth.google import GoogleAuthError


@pytest.fixture
def _patch_db_repo():
    """Patch the exchange-code and session repos so the callback succeeds without a real DB.

    **Outputs:**
    - AsyncMock: The ``AuthExchangeCodesRepository`` mock (the callback's writer),
      with ``create`` patched to return ``None``.
    """
    exchange_repo = AsyncMock()
    exchange_repo.create.return_value = None
    sessions_repo = AsyncMock()
    sessions_repo.create.return_value = None
    fake_session = AsyncMock()
    fake_session_ctx = AsyncMock()
    fake_session_ctx.__aenter__.return_value = fake_session
    fake_session_ctx.__aexit__.return_value = None
    with (
        patch("pulse_server.routers.auth.get_session", return_value=fake_session_ctx),
        patch("pulse_server.routers.auth.AuthExchangeCodesRepository", return_value=exchange_repo),
        patch("pulse_server.routers.auth.SessionsRepository", return_value=sessions_repo),
    ):
        yield exchange_repo


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
    """Verified email outside `ALLOWED_EMAILS` redirects with `error=not_allowed` and skips code creation."""
    client.cookies.set("oauth_state", "s", path="/auth/google")
    client.cookies.set("oauth_pkce", "challenge", path="/auth/google")
    with (
        patch(
            "pulse_server.routers.auth.exchange_code_for_id_token",
            new_callable=AsyncMock,
            return_value="jwt",
        ),
        patch(
            "pulse_server.routers.auth.verify_id_token",
            return_value=("nobody@gmail.com", "sub"),
        ),
    ):
        r = client.get(
            "/auth/google/callback",
            params={"code": "x", "state": "s"},
            follow_redirects=False,
        )
    assert r.status_code == 302
    assert "error=not_allowed" in r.headers["location"]
    _patch_db_repo.create.assert_not_called()


def test_callback_happy_path_stores_exchange_code_and_redirects_with_code(client, _patch_db_repo):
    """Successful callback stores a one-time code and redirects with `code` only (no token/email)."""
    client.cookies.set("oauth_state", "s", path="/auth/google")
    client.cookies.set("oauth_pkce", "challenge", path="/auth/google")
    with (
        patch(
            "pulse_server.routers.auth.exchange_code_for_id_token",
            new_callable=AsyncMock,
            return_value="jwt",
        ),
        patch(
            "pulse_server.routers.auth.verify_id_token",
            return_value=("khashzd@gmail.com", "sub"),
        ),
    ):
        r = client.get(
            "/auth/google/callback",
            params={"code": "x", "state": "s"},
            follow_redirects=False,
        )
    assert r.status_code == 302
    loc = r.headers["location"]
    assert loc.startswith("diettracker://auth?")
    assert "code=" in loc
    assert "token=" not in loc
    assert "email=" not in loc
    _patch_db_repo.create.assert_awaited_once()


def test_callback_without_pkce_cookie_redirects_invalid_request(client):
    """A callback missing the PKCE cookie (set at start) redirects with `error=invalid_request`."""
    client.cookies.set("oauth_state", "s", path="/auth/google")
    r = client.get(
        "/auth/google/callback",
        params={"code": "x", "state": "s"},
        follow_redirects=False,
    )
    assert r.status_code == 302
    assert "error=invalid_request" in r.headers["location"]


def test_callback_token_exchange_failure_redirects_server_error(client):
    """`GoogleAuthError` from token exchange redirects with `error=server_error`."""
    client.cookies.set("oauth_state", "s", path="/auth/google")
    client.cookies.set("oauth_pkce", "challenge", path="/auth/google")
    with patch(
        "pulse_server.routers.auth.exchange_code_for_id_token",
        new_callable=AsyncMock,
        side_effect=GoogleAuthError("boom"),
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
    client.cookies.set("oauth_pkce", "challenge", path="/auth/google")
    r = client.get(
        "/auth/google/callback",
        params={"state": "s"},  # no code
        follow_redirects=False,
    )
    assert r.status_code == 302
    assert "error=invalid_callback" in r.headers["location"]


def test_exchange_valid_code_returns_token(client):
    """`POST /auth/google/exchange` with a valid code + matching verifier returns a bearer token."""
    from datetime import datetime as DT
    from datetime import timedelta as TD

    from pulse_server.auth.sessions import pkce_s256_challenge

    verifier = "v" * 48
    challenge = pkce_s256_challenge(verifier)
    fut = DT.now(UTC) + TD(seconds=120)

    exchange_repo = AsyncMock()
    exchange_repo.consume.return_value = {
        "email": "khashzd@gmail.com",
        "code_challenge": challenge,
        "expires_at": fut,
    }
    sessions_repo = AsyncMock()
    sessions_repo.create.return_value = None

    fake_session = AsyncMock()
    ctx = AsyncMock()
    ctx.__aenter__.return_value = fake_session
    ctx.__aexit__.return_value = None
    with (
        patch("pulse_server.routers.auth.get_session", return_value=ctx),
        patch("pulse_server.routers.auth.AuthExchangeCodesRepository", return_value=exchange_repo),
        patch("pulse_server.routers.auth.SessionsRepository", return_value=sessions_repo),
    ):
        r = client.post(
            "/auth/google/exchange",
            json={"code": "one-time", "code_verifier": verifier},
        )
    assert r.status_code == 200
    body = r.json()
    assert body["email"] == "khashzd@gmail.com"
    assert body["token"]
    sessions_repo.create.assert_awaited_once()


def test_exchange_wrong_verifier_rejected(client):
    """A verifier that doesn't match the stored challenge is rejected and no session is created."""
    from datetime import datetime as DT
    from datetime import timedelta as TD

    from pulse_server.auth.sessions import pkce_s256_challenge

    fut = DT.now(UTC) + TD(seconds=120)
    exchange_repo = AsyncMock()
    exchange_repo.consume.return_value = {
        "email": "khashzd@gmail.com",
        "code_challenge": pkce_s256_challenge("the-real-verifier"),
        "expires_at": fut,
    }
    sessions_repo = AsyncMock()

    fake_session = AsyncMock()
    ctx = AsyncMock()
    ctx.__aenter__.return_value = fake_session
    ctx.__aexit__.return_value = None
    with (
        patch("pulse_server.routers.auth.get_session", return_value=ctx),
        patch("pulse_server.routers.auth.AuthExchangeCodesRepository", return_value=exchange_repo),
        patch("pulse_server.routers.auth.SessionsRepository", return_value=sessions_repo),
    ):
        r = client.post(
            "/auth/google/exchange",
            json={"code": "one-time", "code_verifier": "w" * 43},  # valid length, wrong value
        )
    assert r.status_code == 400
    sessions_repo.create.assert_not_called()


def test_exchange_unknown_code_rejected(client):
    """An unknown/already-used code (consume returns None) is rejected with 400."""
    exchange_repo = AsyncMock()
    exchange_repo.consume.return_value = None

    fake_session = AsyncMock()
    ctx = AsyncMock()
    ctx.__aenter__.return_value = fake_session
    ctx.__aexit__.return_value = None
    with (
        patch("pulse_server.routers.auth.get_session", return_value=ctx),
        patch("pulse_server.routers.auth.AuthExchangeCodesRepository", return_value=exchange_repo),
    ):
        r = client.post(
            "/auth/google/exchange",
            json={"code": "nope", "code_verifier": "v" * 43},
        )
    assert r.status_code == 400


def test_exchange_non_ascii_verifier_rejected_not_500(client):
    """A non-ASCII (but valid-length) verifier is rejected with 400, never a 500."""
    from datetime import datetime as DT
    from datetime import timedelta as TD

    fut = DT.now(UTC) + TD(seconds=120)
    exchange_repo = AsyncMock()
    exchange_repo.consume.return_value = {
        "email": "khashzd@gmail.com",
        "code_challenge": "anything",
        "expires_at": fut,
    }
    sessions_repo = AsyncMock()

    fake_session = AsyncMock()
    ctx = AsyncMock()
    ctx.__aenter__.return_value = fake_session
    ctx.__aexit__.return_value = None
    with (
        patch("pulse_server.routers.auth.get_session", return_value=ctx),
        patch("pulse_server.routers.auth.AuthExchangeCodesRepository", return_value=exchange_repo),
        patch("pulse_server.routers.auth.SessionsRepository", return_value=sessions_repo),
    ):
        r = client.post(
            "/auth/google/exchange",
            json={"code": "one-time", "code_verifier": "é" * 50},  # non-ASCII, length 50
        )
    assert r.status_code == 400
    sessions_repo.create.assert_not_called()


def test_exchange_too_short_verifier_rejected_422(client):
    """A verifier shorter than RFC 7636's 43-char minimum is rejected at the model (422)."""
    r = client.post(
        "/auth/google/exchange",
        json={"code": "one-time", "code_verifier": "tooshort"},
    )
    assert r.status_code == 422


def test_verify_pkce_s256_non_ascii_returns_false():
    """`verify_pkce_s256` returns False (not raises) for a non-ASCII verifier."""
    from pulse_server.auth.sessions import verify_pkce_s256

    assert verify_pkce_s256("é" * 43, "any-challenge") is False


def test_whoami_unauthenticated_returns_401(client):
    """`/auth/whoami` without a Bearer token returns 401."""
    r = client.get("/auth/whoami")
    assert r.status_code == 401


def test_whoami_returns_email_and_expires_at(client):
    """`/auth/whoami` with a valid session returns the email and expiry."""
    from datetime import datetime as DT
    from datetime import timedelta as TD

    fut = DT.now(UTC) + TD(days=7)
    fake_repo = AsyncMock()
    fake_repo.get.return_value = {"email": "khashzd@gmail.com", "expires_at": fut}
    fake_repo.slide.return_value = 1

    fake_session = AsyncMock()
    ctx = AsyncMock()
    ctx.__aenter__.return_value = fake_session
    ctx.__aexit__.return_value = None
    with (
        patch("pulse_server.auth.middleware.get_session", return_value=ctx),
        patch("pulse_server.auth.middleware.SessionsRepository", return_value=fake_repo),
    ):
        r = client.get("/auth/whoami", headers={"Authorization": "Bearer tok"})
    assert r.status_code == 200
    body = r.json()
    assert body["email"] == "khashzd@gmail.com"
    assert "expires_at" in body


def test_logout_deletes_session_and_returns_204(client):
    """`/auth/logout` deletes the session row and returns 204."""
    from datetime import datetime as DT
    from datetime import timedelta as TD

    fut = DT.now(UTC) + TD(days=7)
    fake_repo = AsyncMock()
    fake_repo.get.return_value = {"email": "u@e.com", "expires_at": fut}
    fake_repo.slide.return_value = 1
    fake_repo.delete.return_value = 1

    fake_session = AsyncMock()
    ctx = AsyncMock()
    ctx.__aenter__.return_value = fake_session
    ctx.__aexit__.return_value = None
    with (
        patch("pulse_server.auth.middleware.get_session", return_value=ctx),
        patch("pulse_server.auth.middleware.SessionsRepository", return_value=fake_repo),
        patch("pulse_server.routers.auth.get_session", return_value=ctx),
        patch("pulse_server.routers.auth.SessionsRepository", return_value=fake_repo),
    ):
        r = client.post("/auth/logout", headers={"Authorization": "Bearer tok"})
    assert r.status_code == 204
    fake_repo.delete.assert_awaited()
