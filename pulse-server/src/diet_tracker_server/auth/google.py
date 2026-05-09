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


# Summary: Builds the Google OAuth 2.0 authorize URL the user is redirected to.
# Parameters:
# - state (str): Opaque CSRF token round-tripped via cookie + Google.
# Returns:
# - str: Fully-qualified URL with all required query params.
# Raises/Throws:
# - None: Pure string assembly using the configured Google client id.
def build_authorize_url(*, state: str) -> str:
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


# Summary: Exchanges an authorization code with Google for an ID token.
# Parameters:
# - code (str): Authorization code returned by Google to the callback URL.
# Returns:
# - str: Compact-form JWT ID token string.
# Raises/Throws:
# - GoogleAuthError: On HTTP failure or when the response lacks id_token.
async def exchange_code_for_id_token(*, code: str) -> str:
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
    except httpx.HTTPError as exc:
        raise GoogleAuthError("Google token endpoint failed") from exc

    token = data.get("id_token")
    if not token:
        raise GoogleAuthError("Google response missing id_token")
    return token


# Summary: Verifies a Google-issued ID token and returns the authenticated identity.
# Parameters:
# - jwt_str (str): Compact-form JWT obtained from the token endpoint.
# Returns:
# - tuple[str, str]: (email_lower, sub) extracted from the verified payload.
# Raises/Throws:
# - GoogleAuthError: On signature/claim verification failure or missing email/sub.
def verify_id_token(jwt_str: str) -> tuple[str, str]:
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
