from __future__ import annotations

import base64
import hashlib
import secrets

from diet_tracker_server.config import get_settings


# Summary: Generates a URL-safe random session token of the requested byte length.
# Parameters:
# - num_bytes (int): Number of random bytes to draw before base64url encoding.
# Returns:
# - str: Base64url-encoded token without padding (32 bytes -> 43 chars).
# Raises/Throws:
# - None: Uses secrets.token_bytes which never fails on supported platforms.
def generate_token(*, num_bytes: int) -> str:
    raw = secrets.token_bytes(num_bytes)
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


# Summary: Computes the SHA-256 digest of a UTF-8-encoded session token.
# Parameters:
# - token (str): Opaque session token issued to the client.
# Returns:
# - bytes: 32-byte SHA-256 digest suitable for storage as the sessions PK.
# Raises/Throws:
# - None: hashlib never raises on str input.
def hash_token(token: str) -> bytes:
    return hashlib.sha256(token.encode("utf-8")).digest()


# Summary: Maps an authenticated email to the user_key used for data scoping.
# Parameters:
# - email (str): Authenticated email address from the verified Google ID token.
# Returns:
# - str: The configured legacy_user_key — single-user today; multi-user maps later.
# Raises/Throws:
# - None: Configuration access only.
def email_to_user_key(email: str) -> str:
    del email
    return get_settings().legacy_user_key
