"""Google OAuth 2.0 handshake helpers.

Implements the three steps the auth router needs to integrate with Google:
build the authorize URL the user is redirected to, exchange the returned
authorization code for an ID token, and verify that ID token's signature and
claims to extract the authenticated identity.

Consumed by ``routers/auth.py``; depends only on the Google client libraries
and the app's configuration module. Holds no state.
"""

from __future__ import annotations

from urllib.parse import urlencode

import httpx
from google.auth.transport import requests as google_requests
from google.oauth2 import id_token

from diet_tracker_server.config import get_settings


GOOGLE_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"


class GoogleAuthError(Exception):
    """Raised when the Google OAuth handshake fails for any reason."""


def build_authorize_url(*, state: str) -> str:
    """Build the Google OAuth 2.0 authorize URL the user is redirected to.

    Pure string assembly using the configured Google client id.

    **Inputs:**
    - state (str): Opaque CSRF token round-tripped via cookie + Google.

    **Outputs:**
    - str: Fully-qualified URL with all required query params.
    """
    settings = get_settings()
    params = {
        "client_id": settings.google_client_id,
        "redirect_uri": settings.oauth_redirect_uri,
        "response_type": "code",
        "scope": "openid email profile",
        "state": state,
        "prompt": "select_account",
        "access_type": "online",
    }
    return f"{GOOGLE_AUTHORIZE_URL}?{urlencode(params)}"


async def exchange_code_for_id_token(*, code: str) -> str:
    """Exchange an authorization code with Google for an ID token.

    **Inputs:**
    - code (str): Authorization code returned by Google to the callback URL.

    **Outputs:**
    - str: Compact-form JWT ID token string.

    **Exceptions:**
    - GoogleAuthError: On HTTP failure or when the response lacks ``id_token``.
    """
    settings = get_settings()
    body = {
        "code": code,
        "client_id": settings.google_client_id,
        "client_secret": settings.google_client_secret,
        "redirect_uri": settings.oauth_redirect_uri,
        "grant_type": "authorization_code",
    }
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(GOOGLE_TOKEN_URL, data=body)
            resp.raise_for_status()
            data = resp.json()
    except (httpx.HTTPError, ValueError) as exc:
        raise GoogleAuthError("Google token endpoint failed") from exc

    token = data.get("id_token")
    if not token:
        raise GoogleAuthError("Google response missing id_token")
    return token


def verify_id_token(jwt_str: str) -> tuple[str, str]:
    """Verify a Google-issued ID token and return the authenticated identity.

    **Inputs:**
    - jwt_str (str): Compact-form JWT obtained from the token endpoint.

    **Outputs:**
    - tuple[str, str]: ``(email_lower, sub)`` extracted from the verified payload.

    **Exceptions:**
    - GoogleAuthError: On signature/claim verification failure or missing
      ``email``/``sub``.
    """
    settings = get_settings()
    try:
        payload = id_token.verify_oauth2_token(
            jwt_str,
            google_requests.Request(),
            settings.google_client_id,
        )
    except ValueError as exc:
        raise GoogleAuthError(f"id_token verification failed: {exc}") from exc

    email = payload.get("email")
    sub = payload.get("sub")
    if not email or not sub:
        raise GoogleAuthError("id_token payload missing email or sub")
    return email.strip().lower(), sub
