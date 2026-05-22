"""Auth package public surface.

Re-exports the session-auth middleware, the ``user_key`` query-param guardrail
middleware, and the ``require_session`` FastAPI dependency so the rest of the
codebase can import them from ``pulse_server.auth`` directly.

This package owns the Google OAuth handshake, opaque session token issuance and
storage, request-scope authentication, and the cutover guardrail that rejects
the legacy ``?user_key=`` query parameter on protected routes.
"""

from pulse_server.auth.middleware import (
    SessionAuthMiddleware,
    UserKeyGuardrailMiddleware,
    require_session,
)

__all__ = [
    "SessionAuthMiddleware",
    "UserKeyGuardrailMiddleware",
    "require_session",
]
