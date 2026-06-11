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

import asyncio
import logging
import secrets
from datetime import UTC, datetime, timedelta
from urllib.parse import quote

from fastapi import APIRouter, Cookie, Depends, HTTPException, Request
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, Field

from pulse_server.auth import require_session
from pulse_server.auth.google import (
    GoogleAuthError,
    build_authorize_url,
    exchange_code_for_id_token,
    verify_id_token,
)
from pulse_server.auth.sessions import generate_token, hash_token, verify_pkce_s256
from pulse_server.config import get_settings
from pulse_server.db import get_session
from pulse_server.repositories.auth_exchange_codes import AuthExchangeCodesRepository
from pulse_server.repositories.sessions import SessionsRepository
from pulse_server.services.rate_limit import SlidingWindowRateLimiter

logger = logging.getLogger(__name__)


router = APIRouter(prefix="/auth")

# Per-client-IP throttle on the unauthenticated OAuth bootstrap routes. These
# are the only endpoints reachable without a Bearer token, and each hit costs a
# DB round-trip (/exchange consumes a code; /start mints state cookies), so an
# unbounded caller can generate DB load at will. The window is deliberately
# generous — a legitimate login uses one /start and one /exchange.
AUTH_RATE_LIMIT_MAX_REQUESTS = 30
AUTH_RATE_LIMIT_WINDOW_SECONDS = 60.0
_auth_rate_limiter = SlidingWindowRateLimiter(
    max_requests=AUTH_RATE_LIMIT_MAX_REQUESTS,
    window_seconds=AUTH_RATE_LIMIT_WINDOW_SECONDS,
)


def _client_ip(request: Request) -> str:
    """Resolve the caller's IP for rate-limit keying, honoring the proxy header.

    Railway terminates TLS in front of uvicorn, so the peer address is the
    edge proxy; the client is taken from ``X-Forwarded-For``. The RIGHTMOST
    entry is used, never the leftmost: a client can prepend arbitrary values
    to the header, but the last entry is appended by the trusted edge proxy
    itself (one hop on this deployment) and cannot be spoofed — keying on the
    leftmost value would let an attacker rotate fake IPs to mint a fresh
    rate-limit bucket per request.

    **Inputs:**
    - request (Request): Incoming HTTP request.

    **Outputs:**
    - str: Best-effort client IP, or ``"unknown"`` when nothing is available.
    """
    forwarded = request.headers.get("x-forwarded-for", "")
    if forwarded:
        return forwarded.rsplit(",", 1)[-1].strip()
    return request.client.host if request.client else "unknown"


def _enforce_auth_rate_limit(request: Request) -> None:
    """Reject the request with HTTP 429 when its client IP exceeds the auth throttle.

    **Inputs:**
    - request (Request): Incoming HTTP request whose client IP is the limit key.

    **Outputs:**
    - None: Returns nothing when the request is within the limit.

    **Raises:**
    - HTTPException(429): When the client IP has exhausted the window's budget.
    """
    if not _auth_rate_limiter.allow(_client_ip(request)):
        raise HTTPException(
            status_code=429,
            detail="Too many authentication attempts; try again shortly.",
            headers={"Retry-After": str(int(AUTH_RATE_LIMIT_WINDOW_SECONDS))},
        )


STATE_COOKIE_NAME = "oauth_state"
STATE_COOKIE_PATH = "/auth/google"
STATE_COOKIE_MAX_AGE = 600  # 10 minutes

# PKCE: the app sends a code_challenge to /google/start; it is round-tripped
# through this cookie (the challenge is not secret) so the callback can bind it
# to the one-time exchange code.
PKCE_COOKIE_NAME = "oauth_pkce"

# One-time exchange code lifetime. The app redeems it immediately after the
# redirect, so this is intentionally short.
EXCHANGE_CODE_TTL_SECONDS = 120


def _app_redirect(*, error: str | None = None, code: str | None = None) -> RedirectResponse:
    """Build the 302 RedirectResponse to the iOS app's custom-scheme URL.

    On success the redirect carries only a short-lived, single-use exchange
    ``code`` — never the bearer session token. The app redeems that code over
    TLS (with its PKCE verifier) at ``/auth/google/exchange``, so intercepting
    the redirect (e.g. via a hijacked custom scheme) yields nothing usable
    without the verifier.

    **Inputs:**
    - error (str | None): Error code propagated to the iOS client; ``None`` on success.
    - code (str | None): Opaque one-time exchange code issued on success.

    **Outputs:**
    - RedirectResponse: 302 to ``<scheme>://auth?...`` with the OAuth cookies cleared.
    """
    settings = get_settings()
    base = f"{settings.app_redirect_scheme}://auth"
    if error is not None:
        location = f"{base}?error={quote(error)}"
    else:
        assert code is not None
        location = f"{base}?code={quote(code, safe='')}"
    response = RedirectResponse(url=location, status_code=302)
    response.delete_cookie(STATE_COOKIE_NAME, path=STATE_COOKIE_PATH)
    response.delete_cookie(PKCE_COOKIE_NAME, path=STATE_COOKIE_PATH)
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
async def google_start(
    request: Request,
    code_challenge: str | None = None,
    code_challenge_method: str | None = None,
) -> RedirectResponse:
    """Begin Google OAuth: set CSRF + PKCE cookies and redirect to Google's authorize URL.

    PKCE is mandatory: the app must supply an S256 ``code_challenge``. When it is
    missing or uses an unsupported method, the flow is aborted by redirecting
    back to the app with an error (so ASWebAuthenticationSession surfaces it
    rather than hanging).

    **Inputs:**
    - request (Request): Incoming HTTP request used to decide the cookie ``Secure`` flag.
    - code_challenge (str | None): PKCE S256 challenge generated by the app.
    - code_challenge_method (str | None): PKCE method; only ``S256`` is accepted
      (defaults to ``S256`` when omitted).

    **Outputs:**
    - RedirectResponse: 302 to Google with the state echoed in the query string,
      or a 302 back to the app's scheme with ``error=invalid_request`` when the
      PKCE challenge is absent or malformed.

    **Raises:**
    - HTTPException(429): When the client IP exceeds the auth rate limit.
    """
    _enforce_auth_rate_limit(request)
    method = code_challenge_method or "S256"
    if not code_challenge or method != "S256":
        logger.info("google start rejected: missing/invalid PKCE challenge")
        return _app_redirect(error="invalid_request")

    state = secrets.token_urlsafe(32)
    location = build_authorize_url(state=state)
    response = RedirectResponse(url=location, status_code=302)
    secure = _is_secure_request(request)
    response.set_cookie(
        key=STATE_COOKIE_NAME,
        value=state,
        max_age=STATE_COOKIE_MAX_AGE,
        path=STATE_COOKIE_PATH,
        secure=secure,
        httponly=True,
        samesite="lax",
    )
    response.set_cookie(
        key=PKCE_COOKIE_NAME,
        value=code_challenge,
        max_age=STATE_COOKIE_MAX_AGE,
        path=STATE_COOKIE_PATH,
        secure=secure,
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
    oauth_pkce: str | None = Cookie(default=None),
) -> RedirectResponse:
    """Complete the Google OAuth handshake, mint a one-time code, and 302 back to the app.

    Validates the CSRF state cookie, exchanges the authorization code for an ID
    token, verifies the email is in the allowlist, then stores a short-lived,
    single-use exchange code bound to the PKCE challenge and redirects to the
    app's custom scheme with that ``code`` — not the bearer token. The app
    redeems the code at ``/auth/google/exchange``. Any failure is surfaced as
    ``?error=<code>`` rather than a non-2xx HTTP response.

    **Inputs:**
    - request (Request): Incoming HTTP request (used to read the cookies).
    - code (str | None): Authorization code from Google on success.
    - state (str | None): CSRF state echoed by Google.
    - error (str | None): Error code from Google when the user denies consent.
    - oauth_state (str | None): Server-set CSRF cookie scoped to ``/auth/google``.
    - oauth_pkce (str | None): Server-set PKCE challenge cookie scoped to ``/auth/google``.

    **Outputs:**
    - RedirectResponse: 302 to the app scheme with a one-time ``code`` on success,
      or ``?error=<code>`` on failure.
    """
    if error:
        logger.info("google denied auth: %s", error)
        return _app_redirect(error="access_denied")

    # compare_digest for consistency with the PKCE verifier check — the state
    # has 256 bits of entropy so a timing oracle is impractical, but there is
    # no reason to leave one comparison in the auth path non-constant-time.
    if not state or not oauth_state or not secrets.compare_digest(state, oauth_state):
        return _app_redirect(error="invalid_state")

    if not oauth_pkce:
        # PKCE challenge missing — the start step set this cookie, so its absence
        # means a tampered or out-of-band flow.
        return _app_redirect(error="invalid_request")

    if not code:
        return _app_redirect(error="invalid_callback")

    try:
        id_token_jwt = await exchange_code_for_id_token(code=code)
        # verify_id_token uses google-auth's sync HTTP transport to fetch
        # Google's signing certs — run it off the event loop.
        email, _sub = await asyncio.to_thread(verify_id_token, id_token_jwt)
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

    exchange_code = generate_token(num_bytes=settings.session_token_bytes)
    now = datetime.now(UTC)
    expires_at = now + timedelta(seconds=EXCHANGE_CODE_TTL_SECONDS)

    async with get_session() as db_session:
        repo = AuthExchangeCodesRepository(db_session)
        await repo.create(
            code_hash=hash_token(exchange_code),
            email=email,
            code_challenge=oauth_pkce,
            now=now,
            expires_at=expires_at,
        )
        await db_session.commit()

    return _app_redirect(code=exchange_code)


class ExchangeRequest(BaseModel):
    """Request body for ``POST /auth/google/exchange``.

    Field bounds reject obviously-malformed unauthenticated input at the edge
    (422) and cap payload size; an RFC 7636 ``code_verifier`` is 43-128 chars.
    """

    code: str = Field(min_length=1, max_length=512)
    code_verifier: str = Field(min_length=43, max_length=128)


class ExchangeResponse(BaseModel):
    """Response body for a successful exchange: the bearer token and identity."""

    token: str
    email: str
    expires_at: datetime


@router.post("/google/exchange", response_model=ExchangeResponse)
async def google_exchange(request: Request, body: ExchangeRequest) -> ExchangeResponse:
    """Redeem a one-time exchange code with its PKCE verifier for a session token.

    The code is consumed (deleted) on first lookup regardless of outcome, so it
    is strictly single-use and a wrong verifier cannot be retried. On success a
    new Bearer session is minted and returned over the (TLS) response body — the
    token is never placed in a URL.

    **Inputs:**
    - request (Request): Incoming HTTP request, used for rate-limit keying by client IP.
    - body (ExchangeRequest): The one-time ``code`` and the PKCE ``code_verifier``.

    **Outputs:**
    - ExchangeResponse: The bearer ``token``, authenticated ``email``, and session ``expires_at``.

    **Raises:**
    - HTTPException(400): When the code is unknown/already used/expired, or the
      PKCE verifier does not match.
    - HTTPException(429): When the client IP exceeds the auth rate limit.
    """
    _enforce_auth_rate_limit(request)
    settings = get_settings()
    now = datetime.now(UTC)

    token = generate_token(num_bytes=settings.session_token_bytes)
    session_expires_at = now + timedelta(days=settings.session_ttl_days)

    # Non-None only when the code is found, unexpired, and the PKCE verifier matches.
    authenticated_email: str | None = None
    async with get_session() as db_session:
        row = await AuthExchangeCodesRepository(db_session).consume(hash_token(body.code))
        if (
            row is not None
            and row["expires_at"] > now
            and verify_pkce_s256(body.code_verifier, row["code_challenge"])
        ):
            authenticated_email = row["email"]
            await SessionsRepository(db_session).create(
                token_hash=hash_token(token),
                email=authenticated_email,
                now=now,
                expires_at=session_expires_at,
            )
        # Commit unconditionally so the DELETE (single-use consumption) persists
        # even when the redemption is rejected.
        await db_session.commit()

    if authenticated_email is None:
        raise HTTPException(status_code=400, detail="invalid_or_expired_code")

    return ExchangeResponse(token=token, email=authenticated_email, expires_at=session_expires_at)


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
