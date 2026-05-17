"""Google-OAuth-backed session endpoints for the iOS client.

Exposes the ``/auth`` router that handles the OAuth handshake start/callback,
session introspection (``/whoami``), and logout. The callback exchanges the
Google authorization code for an ID token, validates it against the configured
allowlist, mints an opaque session token, persists ``sha256(token)`` via
:class:`SessionsRepository`, and 302s back to the iOS app's custom URL scheme.

Sits at the edge of the request pipeline: every other router relies on
``SessionAuthMiddleware`` validating tokens that this module issues.
"""

from __future__ import annotations

import logging
import secrets
from datetime import datetime, timedelta, timezone
from urllib.parse import quote

from fastapi import APIRouter, Cookie, Depends, Request
from fastapi.responses import RedirectResponse
from pydantic import BaseModel

from diet_tracker_server.auth import require_session
from diet_tracker_server.auth.google import (
    GoogleAuthError,
    build_authorize_url,
    exchange_code_for_id_token,
    verify_id_token,
)
from diet_tracker_server.auth.sessions import generate_token, hash_token
from diet_tracker_server.config import get_settings
from diet_tracker_server.db import get_session
from diet_tracker_server.repositories.sessions import SessionsRepository


logger = logging.getLogger(__name__)


router = APIRouter(prefix="/auth")


STATE_COOKIE_NAME = "oauth_state"
STATE_COOKIE_PATH = "/auth/google"
STATE_COOKIE_MAX_AGE = 600  # 10 minutes


def _app_redirect(*, error: str | None = None, token: str | None = None, email: str | None = None) -> RedirectResponse:
    """Build the 302 RedirectResponse to the iOS app's custom-scheme URL.

    **Inputs:**
    - error (str | None): Error code propagated to the iOS client; ``None`` on success.
    - token (str | None): Opaque session token issued on success.
    - email (str | None): Authenticated email echoed back on success.

    **Outputs:**
    - RedirectResponse: 302 to ``<scheme>://auth?...`` with the state cookie cleared.
    """
    settings = get_settings()
    base = f"{settings.app_redirect_scheme}://auth"
    if error is not None:
        location = f"{base}?error={quote(error)}"
    else:
        assert token is not None and email is not None
        location = f"{base}?token={quote(token, safe='')}&email={quote(email, safe='')}"
    response = RedirectResponse(url=location, status_code=302)
    response.delete_cookie(STATE_COOKIE_NAME, path=STATE_COOKIE_PATH)
    return response


def _is_secure_request(request: Request) -> bool:
    """Detect whether the request reached the server over TLS.

    **Inputs:**
    - request (Request): Incoming HTTP request.

    **Outputs:**
    - bool: ``True`` when scheme is ``https`` or ``x-forwarded-proto`` reports ``https``.
    """
    return request.url.scheme == "https" or request.headers.get("x-forwarded-proto") == "https"


@router.get("/google/start")
async def google_start(request: Request) -> RedirectResponse:
    """Begin Google OAuth: set a CSRF state cookie and redirect to Google's authorize URL.

    **Inputs:**
    - request (Request): Incoming HTTP request used to decide the cookie ``Secure`` flag.

    **Outputs:**
    - RedirectResponse: 302 to Google with the state echoed in the query string.
    """
    state = secrets.token_urlsafe(32)
    location = build_authorize_url(state=state)
    response = RedirectResponse(url=location, status_code=302)
    response.set_cookie(
        key=STATE_COOKIE_NAME,
        value=state,
        max_age=STATE_COOKIE_MAX_AGE,
        path=STATE_COOKIE_PATH,
        secure=_is_secure_request(request),
        httponly=True,
        samesite="lax",
    )
    return response


@router.get("/google/callback")
async def google_callback(
    request: Request,
    code: str | None = None,
    state: str | None = None,
    error: str | None = None,
    oauth_state: str | None = Cookie(default=None),
) -> RedirectResponse:
    """Complete the Google OAuth handshake, mint a session, and 302 back to the iOS app.

    Validates the CSRF state cookie, exchanges the authorization code for an ID
    token, verifies the email is in the allowlist, persists a hashed session
    token, and redirects to the app's custom scheme with ``token`` and
    ``email``. Any failure is surfaced as ``?error=<code>`` rather than a
    non-2xx HTTP response.

    **Inputs:**
    - request (Request): Incoming HTTP request (used to read the state cookie).
    - code (str | None): Authorization code from Google on success.
    - state (str | None): CSRF state echoed by Google.
    - error (str | None): Error code from Google when the user denies consent.
    - oauth_state (str | None): Server-set CSRF cookie scoped to ``/auth/google``.

    **Outputs:**
    - RedirectResponse: 302 to the app scheme with ``token``+``email`` on success,
      or ``?error=<code>`` on failure.
    """
    if error:
        logger.info("google denied auth: %s", error)
        return _app_redirect(error="access_denied")

    if not state or not oauth_state or state != oauth_state:
        return _app_redirect(error="invalid_state")

    if not code:
        return _app_redirect(error="invalid_callback")

    try:
        id_token_jwt = await exchange_code_for_id_token(code=code)
        email, _sub = verify_id_token(id_token_jwt)
    except GoogleAuthError as exc:
        logger.warning("google oauth handshake failed: %s", exc)
        return _app_redirect(error="server_error")
    except Exception:  # pragma: no cover
        logger.exception("unexpected error in google callback")
        return _app_redirect(error="server_error")

    settings = get_settings()
    if email not in settings.allowed_emails_set:
        logger.info("rejected sign-in for non-allowlisted email: %s", email)
        return _app_redirect(error="not_allowed")

    token = generate_token(num_bytes=settings.session_token_bytes)
    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(days=settings.session_ttl_days)

    async with get_session() as db_session:
        repo = SessionsRepository(db_session)
        await repo.create(
            token_hash=hash_token(token),
            email=email,
            now=now,
            expires_at=expires_at,
        )
        await db_session.commit()

    return _app_redirect(token=token, email=email)


class WhoamiResponse(BaseModel):
    email: str
    expires_at: datetime


@router.get("/whoami", response_model=WhoamiResponse, dependencies=[Depends(require_session)])
async def whoami(request: Request) -> WhoamiResponse:
    """Return the authenticated session's identity and post-slide expiry.

    **Inputs:**
    - request (Request): Active request whose ``state`` was populated by ``SessionAuthMiddleware``.

    **Outputs:**
    - WhoamiResponse: ``email`` and ``expires_at`` after the session TTL slide.

    **Exceptions:**
    - HTTPException(401): Raised by ``require_session`` when no session is attached.
    """
    return WhoamiResponse(
        email=request.state.email,
        expires_at=request.state.session_expires_at,
    )


@router.post("/logout", status_code=204, dependencies=[Depends(require_session)])
async def logout(request: Request) -> None:
    """Delete the current session row server-side and return HTTP 204.

    **Inputs:**
    - request (Request): Active request used to extract the Bearer token.

    **Exceptions:**
    - HTTPException(401): Raised by ``require_session`` when no session is attached.
    """
    header = request.headers.get("authorization", "")
    token = header[7:].strip()
    async with get_session() as db_session:
        repo = SessionsRepository(db_session)
        await repo.delete(hash_token(token))
        await db_session.commit()
