"""Unit tests for the Google OAuth helper module.

Covers ``build_authorize_url`` query construction, the
``exchange_code_for_id_token`` HTTPX call and its error paths (non-2xx,
missing ``id_token``, malformed JSON), and ``verify_id_token`` payload
parsing including email normalization and missing/invalid signature
failures. The Google network and ``id_token`` verifier are stubbed.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, patch

import httpx
import pytest


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    """Populate the env vars required by ``Settings`` for every test in this module.

    **Inputs:**
    - monkeypatch (pytest.MonkeyPatch): Used to set env vars and reset the settings cache.
    """
    monkeypatch.setenv("DATABASE_URL", "postgresql://localhost/test")
    monkeypatch.setenv("USDA_API_KEY", "x")
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "cid.apps.googleusercontent.com")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "secret")
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "https://api.example.com/auth/google/callback")
    monkeypatch.setenv("APP_REDIRECT_SCHEME", "diettracker")
    monkeypatch.setenv("ALLOWED_EMAILS", "khashzd@gmail.com")
    monkeypatch.setenv("LEGACY_USER_KEY", "khash")
    monkeypatch.setenv("APP_ENV", "local")
    from pulse_server.config import get_settings

    get_settings.cache_clear()


def test_build_authorize_url_includes_required_params():
    """`build_authorize_url` produces a Google authorize URL with all required OAuth params."""
    from pulse_server.auth.google import build_authorize_url

    url = build_authorize_url(state="abc123")
    assert url.startswith("https://accounts.google.com/o/oauth2/v2/auth?")
    assert "client_id=cid.apps.googleusercontent.com" in url
    assert "redirect_uri=https%3A%2F%2Fapi.example.com%2Fauth%2Fgoogle%2Fcallback" in url
    assert "response_type=code" in url
    assert ("scope=openid+email+profile" in url) or ("scope=openid%20email%20profile" in url)
    assert "state=abc123" in url
    assert "prompt=select_account" in url
    assert "access_type=online" in url


@pytest.mark.asyncio
async def test_exchange_code_for_id_token_calls_google():
    """`exchange_code_for_id_token` posts the OAuth payload to Google and returns the id_token string."""
    from pulse_server.auth import google as g

    mock_client = AsyncMock()
    mock_response = AsyncMock()
    mock_response.status_code = 200
    mock_response.json = lambda: {"id_token": "fake.jwt.value"}
    mock_response.raise_for_status = lambda: None
    mock_client.__aenter__.return_value = mock_client
    mock_client.__aexit__.return_value = None
    mock_client.post.return_value = mock_response

    with patch("pulse_server.auth.google.httpx.AsyncClient", return_value=mock_client):
        id_token_str = await g.exchange_code_for_id_token(code="auth_code")

    assert id_token_str == "fake.jwt.value"
    args, kwargs = mock_client.post.call_args
    assert args[0] == "https://oauth2.googleapis.com/token"
    body = kwargs["data"]
    assert body["code"] == "auth_code"
    assert body["client_id"] == "cid.apps.googleusercontent.com"
    assert body["client_secret"] == "secret"
    assert body["redirect_uri"] == "https://api.example.com/auth/google/callback"
    assert body["grant_type"] == "authorization_code"


@pytest.mark.asyncio
async def test_exchange_code_raises_on_non_2xx():
    """`exchange_code_for_id_token` wraps non-2xx Google responses in `GoogleAuthError`."""
    from pulse_server.auth import google as g

    mock_client = AsyncMock()
    mock_response = AsyncMock()
    mock_response.status_code = 400

    def _raise():
        raise httpx.HTTPStatusError(
            "bad", request=httpx.Request("POST", "x"), response=httpx.Response(400)
        )

    mock_response.raise_for_status = _raise
    mock_client.__aenter__.return_value = mock_client
    mock_client.__aexit__.return_value = None
    mock_client.post.return_value = mock_response

    with patch("pulse_server.auth.google.httpx.AsyncClient", return_value=mock_client):
        with pytest.raises(g.GoogleAuthError):
            await g.exchange_code_for_id_token(code="bad")


@pytest.mark.asyncio
async def test_exchange_code_raises_when_id_token_missing():
    """`exchange_code_for_id_token` raises `GoogleAuthError` when the response lacks an id_token."""
    from pulse_server.auth import google as g

    mock_client = AsyncMock()
    mock_response = AsyncMock()
    mock_response.status_code = 200
    mock_response.json = lambda: {"access_token": "x"}  # no id_token
    mock_response.raise_for_status = lambda: None
    mock_client.__aenter__.return_value = mock_client
    mock_client.__aexit__.return_value = None
    mock_client.post.return_value = mock_response

    with patch("pulse_server.auth.google.httpx.AsyncClient", return_value=mock_client):
        with pytest.raises(g.GoogleAuthError, match="missing id_token"):
            await g.exchange_code_for_id_token(code="x")


def test_verify_id_token_returns_email_and_sub():
    """`verify_id_token` returns the lowercased email and Google subject from a valid JWT payload."""
    from pulse_server.auth import google as g

    payload = {
        "email": "Khashzd@Gmail.com",
        "email_verified": True,
        "sub": "1234567890",
        "aud": "cid.apps.googleusercontent.com",
    }
    with patch("pulse_server.auth.google.id_token.verify_oauth2_token", return_value=payload):
        email, sub = g.verify_id_token("jwt-here")
    assert email == "khashzd@gmail.com"  # lowercased + stripped
    assert sub == "1234567890"


def test_verify_id_token_accepts_stringified_email_verified():
    """`verify_id_token` treats a "true" string `email_verified` as verified."""
    from pulse_server.auth import google as g

    payload = {"email": "x@example.com", "email_verified": "true", "sub": "1"}
    with patch("pulse_server.auth.google.id_token.verify_oauth2_token", return_value=payload):
        email, sub = g.verify_id_token("jwt-here")
    assert email == "x@example.com"
    assert sub == "1"


def test_verify_id_token_rejects_unverified_email():
    """`verify_id_token` raises when `email_verified` is false or absent."""
    from pulse_server.auth import google as g

    for payload in (
        {"email": "x@example.com", "email_verified": False, "sub": "1"},
        {"email": "x@example.com", "sub": "1"},  # claim absent
    ):
        with patch("pulse_server.auth.google.id_token.verify_oauth2_token", return_value=payload):
            with pytest.raises(g.GoogleAuthError, match="not verified"):
                g.verify_id_token("jwt-here")


def test_verify_id_token_raises_on_invalid():
    """`verify_id_token` raises `GoogleAuthError` when the underlying verifier rejects the JWT."""
    from pulse_server.auth import google as g

    with patch(
        "pulse_server.auth.google.id_token.verify_oauth2_token",
        side_effect=ValueError("bad signature"),
    ):
        with pytest.raises(g.GoogleAuthError):
            g.verify_id_token("jwt-here")


def test_verify_id_token_raises_when_email_missing():
    """`verify_id_token` raises `GoogleAuthError` when the JWT payload omits the email claim."""
    from pulse_server.auth import google as g

    payload = {"sub": "x"}  # no email
    with patch("pulse_server.auth.google.id_token.verify_oauth2_token", return_value=payload):
        with pytest.raises(g.GoogleAuthError, match="missing"):
            g.verify_id_token("jwt-here")


@pytest.mark.asyncio
async def test_exchange_code_raises_on_invalid_json():
    """`exchange_code_for_id_token` raises `GoogleAuthError` when Google returns malformed JSON."""
    from pulse_server.auth import google as g

    mock_client = AsyncMock()
    mock_response = AsyncMock()
    mock_response.status_code = 200

    def _bad_json():
        """Inline ``response.json`` substitute that simulates a JSON decode failure."""
        raise ValueError("not json")

    mock_response.json = _bad_json
    mock_response.raise_for_status = lambda: None
    mock_client.__aenter__.return_value = mock_client
    mock_client.__aexit__.return_value = None
    mock_client.post.return_value = mock_response

    with patch("pulse_server.auth.google.httpx.AsyncClient", return_value=mock_client):
        with pytest.raises(g.GoogleAuthError):
            await g.exchange_code_for_id_token(code="x")
