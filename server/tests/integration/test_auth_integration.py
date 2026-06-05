"""Integration tests for the Google OAuth sign-in flow end-to-end.

Drives the FastAPI app via ``TestClient`` through ``/auth/google/start`` → mocked
Google ``/callback`` → ``/auth/whoami`` → ``/auth/logout``, verifying redirect
locations, the issued Bearer token, session validation, and post-logout 401.
Integration test: hits a real Postgres via ``TEST_DATABASE_URL`` for the
``sessions`` table.
"""

from __future__ import annotations

import asyncio
import os
from unittest.mock import AsyncMock, patch

import pytest
import sqlalchemy as sa
from fastapi.testclient import TestClient

pytestmark = pytest.mark.integration


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    """Configure auth-related environment variables for the duration of each test.

    **Inputs:**
    - monkeypatch: pytest ``MonkeyPatch`` for scoped env mutation.
    """
    if not os.environ.get("TEST_DATABASE_URL"):
        pytest.skip("TEST_DATABASE_URL not set")
    monkeypatch.setenv("DATABASE_URL", os.environ["TEST_DATABASE_URL"])
    monkeypatch.setenv("USDA_API_KEY", "x")
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "cid.apps.googleusercontent.com")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "secret")
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "https://api.example.com/auth/google/callback")
    monkeypatch.setenv("APP_REDIRECT_SCHEME", "diettracker")
    monkeypatch.setenv("ALLOWED_EMAILS", "khashzd@gmail.com")
    monkeypatch.setenv("LEGACY_USER_KEY", "khash")
    monkeypatch.setenv("APP_ENV", "local")
    monkeypatch.setenv("SESSION_TTL_DAYS", "7")
    from pulse_server.config import get_settings

    get_settings.cache_clear()


@pytest.fixture
def client():
    """FastAPI ``TestClient`` with USDA stubbed and the ``sessions`` table truncated.

    **Outputs:**
    - ``TestClient``: client wired against the real app for full request flows.
    """
    with patch("pulse_server.usda.USDAClient") as mock_usda:
        mock_usda.return_value.close = AsyncMock()
        from pulse_server.app import app

        with TestClient(app) as c:
            from pulse_server import db

            async def _truncate():
                async with db.get_session() as s:
                    await s.execute(sa.text("truncate sessions"))
                    await s.execute(sa.text("truncate auth_exchange_codes"))
                    await s.commit()

            asyncio.get_event_loop().run_until_complete(_truncate())
            yield c


def test_full_signin_flow(client):
    """End-to-end OAuth start → callback → PKCE exchange → whoami → logout."""
    from urllib.parse import parse_qs, urlparse

    from pulse_server.auth.sessions import pkce_s256_challenge

    verifier = "verifier-" + "z" * 50
    challenge = pkce_s256_challenge(verifier)

    # /start (PKCE challenge required)
    r = client.get(
        "/auth/google/start",
        params={"code_challenge": challenge, "code_challenge_method": "S256"},
        follow_redirects=False,
    )
    assert r.status_code == 302
    state_cookie = r.cookies.get("oauth_state")
    pkce_cookie = r.cookies.get("oauth_pkce")
    assert state_cookie
    assert pkce_cookie == challenge

    # /callback (mock Google) → returns a one-time code, not the token
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
        client.cookies.set("oauth_state", state_cookie, path="/auth/google")
        client.cookies.set("oauth_pkce", pkce_cookie, path="/auth/google")
        r = client.get(
            "/auth/google/callback",
            params={"code": "x", "state": state_cookie},
            follow_redirects=False,
        )
    assert r.status_code == 302
    loc = r.headers["location"]
    assert loc.startswith("diettracker://auth?")
    assert "token=" not in loc
    one_time_code = parse_qs(urlparse(loc).query)["code"][0]
    assert one_time_code

    # exchange the one-time code (with the PKCE verifier) for the bearer token
    r = client.post(
        "/auth/google/exchange",
        json={"code": one_time_code, "code_verifier": verifier},
    )
    assert r.status_code == 200
    token = r.json()["token"]
    assert token
    assert r.json()["email"] == "khashzd@gmail.com"

    # the code is single-use: a replay fails
    r_replay = client.post(
        "/auth/google/exchange",
        json={"code": one_time_code, "code_verifier": verifier},
    )
    assert r_replay.status_code == 400

    # whoami
    r = client.get("/auth/whoami", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    assert r.json()["email"] == "khashzd@gmail.com"

    # logout
    r = client.post("/auth/logout", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 204

    # whoami again -> 401
    r = client.get("/auth/whoami", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 401
