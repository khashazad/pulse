"""Request-scope authentication middleware and the ``require_session`` dependency.

Defines one Starlette middleware and one FastAPI dependency:

- :class:`SessionAuthMiddleware` validates ``Authorization: Bearer <token>``
  against the ``sessions`` table, slides the TTL, and attaches ``email``,
  ``user_key``, and ``session_expires_at`` to ``request.state``.
- :func:`require_session` is a FastAPI dependency that asserts the middleware
  populated ``request.state`` so handlers can read auth context safely.

Routes that own their own auth lifecycle (the Google OAuth bootstrap, the MCP
mount, FastMCP-emitted OAuth routes) must be passed via the exemption
parameters so they aren't 401'd before their own layer runs.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi import HTTPException, Request
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse

from pulse_server.auth.sessions import email_to_user_key, hash_token
from pulse_server.config import get_settings
from pulse_server.db import get_session
from pulse_server.repositories.sessions import SessionsRepository


# Paths that always bypass session auth. The OAuth bootstrap routes handle their own
# credential lifecycle; /auth/whoami and /auth/logout still require a valid session
# and are intentionally NOT exempted here.
DEFAULT_EXEMPT_PATHS: frozenset[str] = frozenset({"/health"})
DEFAULT_EXEMPT_PREFIXES: tuple[str, ...] = ("/auth/google/",)


class SessionAuthMiddleware(BaseHTTPMiddleware):
    """Validates Bearer session tokens and slides the session TTL.

    Sets ``request.state.email``, ``request.state.user_key``, and
    ``request.state.session_expires_at``. Routes outside this app's REST
    surface (e.g. the MCP mount and FastMCP-emitted OAuth routes) must be
    passed via ``exempt_paths``/``exempt_prefixes`` so they aren't 401'd
    before their own auth layer can run.
    """

    def __init__(
        self,
        app,
        *,
        exempt_paths: frozenset[str] | None = None,
        exempt_prefixes: tuple[str, ...] | None = None,
    ) -> None:
        """Wire the middleware into the ASGI app and merge exemptions with the package defaults.

        **Inputs:**
        - app: Downstream ASGI app.
        - exempt_paths (frozenset[str] | None): Extra exact paths to bypass session auth.
        - exempt_prefixes (tuple[str, ...] | None): Extra path prefixes to bypass session auth.
        """
        super().__init__(app)
        self._exempt_paths = DEFAULT_EXEMPT_PATHS | (exempt_paths or frozenset())
        self._exempt_prefixes = DEFAULT_EXEMPT_PREFIXES + (exempt_prefixes or ())

    def _is_exempt(self, path: str) -> bool:
        """Return whether ``path`` should bypass session auth.

        **Inputs:**
        - path (str): Request path to check against the exemption sets.

        **Outputs:**
        - bool: ``True`` when the path is in the exempt set or matches an exempt prefix.
        """
        if path in self._exempt_paths:
            return True
        return any(path.startswith(prefix) for prefix in self._exempt_prefixes)

    async def dispatch(self, request: Request, call_next):
        """Authenticate the request by Bearer token, sliding the session TTL on success.

        **Inputs:**
        - request (Request): Incoming HTTP request.
        - call_next (Callable): Downstream handler chain.

        **Outputs:**
        - Response: 401 on missing/invalid/expired session, otherwise the
          downstream response.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Surfaces if the sessions DB write
          fails mid-request.
        """
        if self._is_exempt(request.url.path):
            return await call_next(request)

        header = request.headers.get("authorization", "")
        if not header.lower().startswith("bearer "):
            return JSONResponse(status_code=401, content={"error": "Bearer token required"})
        token = header[7:].strip()
        if not token:
            return JSONResponse(status_code=401, content={"error": "Bearer token required"})

        token_hash = hash_token(token)
        settings = get_settings()
        now = datetime.now(timezone.utc)
        new_expires = now + timedelta(days=settings.session_ttl_days)

        async with get_session() as db_session:
            repo = SessionsRepository(db_session)
            row = await repo.get(token_hash)
            if row is None:
                return JSONResponse(status_code=401, content={"error": "Invalid session"})
            if row["expires_at"] <= now:
                await repo.delete(token_hash)
                await db_session.commit()
                return JSONResponse(status_code=401, content={"error": "Session expired"})
            await repo.slide(token_hash=token_hash, now=now, new_expires_at=new_expires)
            await db_session.commit()

        request.state.email = row["email"]
        request.state.user_key = email_to_user_key(row["email"])
        request.state.session_expires_at = new_expires
        return await call_next(request)


async def require_session(request: Request) -> None:
    """FastAPI dependency that asserts a session was attached by the middleware.

    Confirms auth state is present so handlers can read ``request.state`` safely.

    **Inputs:**
    - request (Request): Incoming HTTP request after middleware ran.

    **Exceptions:**
    - HTTPException: 401 when the middleware did not populate
      ``request.state.email``.
    """
    if not getattr(request.state, "email", None):
        raise HTTPException(status_code=401, detail="Authentication required")
    return None
