"""Auth package public surface.

Re-exports the session-auth middleware and the ``require_session`` FastAPI
dependency so the rest of the codebase can import them from
``pulse_server.auth`` directly.

This package owns the Google OAuth handshake, opaque session token issuance
and storage, and request-scope authentication.
"""

from pulse_server.auth.middleware import (
    SessionAuthMiddleware,
    require_session,
)

__all__ = [
    "SessionAuthMiddleware",
    "require_session",
]
