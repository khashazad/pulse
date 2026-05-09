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


# Summary: Builds the 302 RedirectResponse to the iOS app's custom-scheme URL.
# Parameters:
# - error (str | None): Error code propagated to the iOS client; None on success.
# - token (str | None): Opaque session token issued on success.
# - email (str | None): Authenticated email echoed back on success.
# Returns:
# - RedirectResponse: 302 to `<scheme>://auth?...` with the state cookie cleared.
# Raises/Throws:
# - None: All branches return a response unconditionally.
def _app_redirect(*, error: str | None = None, token: str | None = None, email: str | None = None) -> RedirectResponse:
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


# Summary: Detects whether the request reached the server over TLS.
# Parameters:
# - request (Request): Incoming HTTP request.
# Returns:
# - bool: True when scheme is https or x-forwarded-proto reports https.
# Raises/Throws:
# - None: Pure header inspection.
def _is_secure_request(request: Request) -> bool:
    return request.url.scheme == "https" or request.headers.get("x-forwarded-proto") == "https"


# Summary: Begins Google OAuth: sets a state cookie and redirects to Google's authorize URL.
# Parameters:
# - request (Request): Incoming HTTP request used to decide cookie Secure flag.
# Returns:
# - RedirectResponse: 302 to Google with the state echoed in the query string.
# Raises/Throws:
# - None: All work is local random + URL build.
@router.get("/google/start")
async def google_start(request: Request) -> RedirectResponse:
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


# Summary: Completes the Google OAuth handshake and 302s back to the iOS app.
# Parameters:
# - request (Request): Incoming HTTP request (used to read the state cookie).
# - code (str | None): Authorization code from Google on success.
# - state (str | None): CSRF state echoed by Google.
# - error (str | None): Error code from Google when the user denies.
# - oauth_state (str | None): Server-set CSRF cookie scoped to /auth/google.
# Returns:
# - RedirectResponse: 302 to the app scheme with token+email or error code.
# Raises/Throws:
# - None: All exit paths produce a redirect; failures are surfaced as `?error=...`.
@router.get("/google/callback")
async def google_callback(
    request: Request,
    code: str | None = None,
    state: str | None = None,
    error: str | None = None,
    oauth_state: str | None = Cookie(default=None),
) -> RedirectResponse:
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


# Summary: Returns the authenticated session's identity and post-slide expiry.
# Parameters:
# - request (Request): Active request whose state was populated by the middleware.
# Returns:
# - WhoamiResponse: Email and expires_at after the session slide.
# Raises/Throws:
# - HTTPException(401): When no session is attached (handled by `require_session`).
@router.get("/whoami", response_model=WhoamiResponse, dependencies=[Depends(require_session)])
async def whoami(request: Request) -> WhoamiResponse:
    return WhoamiResponse(
        email=request.state.email,
        expires_at=request.state.session_expires_at,
    )


# Summary: Deletes the current session row and returns 204.
# Parameters:
# - request (Request): Active request used to extract the Bearer token.
# Returns:
# - None: HTTP 204 with no body.
# Raises/Throws:
# - HTTPException(401): When no session is attached (handled by `require_session`).
@router.post("/logout", status_code=204, dependencies=[Depends(require_session)])
async def logout(request: Request) -> None:
    header = request.headers.get("authorization", "")
    token = header[7:].strip()
    async with get_session() as db_session:
        repo = SessionsRepository(db_session)
        await repo.delete(hash_token(token))
        await db_session.commit()
