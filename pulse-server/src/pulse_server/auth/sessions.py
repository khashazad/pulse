"""Session-token primitives and email-to-user_key mapping.

Provides the small, dependency-free helpers used by the OAuth callback and the
session middleware: opaque URL-safe token generation, the SHA-256 hashing used
as the storage key in the ``sessions`` table, and the single-user mapping from
authenticated email to the internal ``user_key`` that scopes all data rows.

Sits below the auth middleware and the sessions repository; it owns no I/O and
holds no state.
"""

from __future__ import annotations

import base64
import hashlib
import secrets

from pulse_server.config import get_settings


def generate_token(*, num_bytes: int) -> str:
    """Generate a URL-safe random session token of the requested byte length.

    **Inputs:**
    - num_bytes (int): Number of random bytes to draw before base64url encoding.

    **Outputs:**
    - str: Base64url-encoded token without padding (32 bytes -> 43 chars).
    """
    raw = secrets.token_bytes(num_bytes)
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def hash_token(token: str) -> bytes:
    """Compute the SHA-256 digest of a UTF-8-encoded session token.

    **Inputs:**
    - token (str): Opaque session token issued to the client.

    **Outputs:**
    - bytes: 32-byte SHA-256 digest suitable for storage as the sessions PK.
    """
    return hashlib.sha256(token.encode("utf-8")).digest()


def email_to_user_key(email: str) -> str:
    """Map an authenticated email to the ``user_key`` used for data scoping.

    Single-user today: returns the configured ``legacy_user_key`` regardless of
    the input email. Multi-user mapping will be introduced later.

    **Inputs:**
    - email (str): Authenticated email address from the verified Google ID token.

    **Outputs:**
    - str: The configured ``legacy_user_key``.
    """
    del email
    return get_settings().legacy_user_key
