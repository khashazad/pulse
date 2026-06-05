"""Unit tests for the session-token helpers in `pulse_server.auth.sessions`.

Covers token generation (length, alphabet, uniqueness), SHA-256 hashing of
tokens, and the single-user `email_to_user_key` shim that maps any email to
the legacy user key configured via env.
"""

from __future__ import annotations

import hashlib

from pulse_server.auth.sessions import (
    email_to_user_key,
    generate_token,
    hash_token,
)


def test_generate_token_url_safe_and_long_enough():
    """`generate_token(32)` returns a 43-char base64url string with no padding."""
    tok = generate_token(num_bytes=32)
    assert isinstance(tok, str)
    # base64url without padding: 32 bytes -> 43 chars
    assert len(tok) == 43
    assert all(c.isalnum() or c in "-_" for c in tok)


def test_generate_token_unique():
    """Two successive calls to `generate_token` produce different tokens."""
    a = generate_token(num_bytes=32)
    b = generate_token(num_bytes=32)
    assert a != b


def test_hash_token_is_sha256_of_utf8():
    """`hash_token` returns the SHA-256 digest of the UTF-8-encoded token."""
    tok = "hello"
    assert hash_token(tok) == hashlib.sha256(b"hello").digest()


def test_email_to_user_key_returns_legacy_value(monkeypatch):
    """`email_to_user_key` returns the configured legacy user key for any input email."""
    monkeypatch.setenv("LEGACY_USER_KEY", "khash")
    monkeypatch.setenv("DATABASE_URL", "postgresql://localhost/test")
    monkeypatch.setenv("USDA_API_KEY", "x")
    monkeypatch.setenv("ALLOWED_EMAILS", "khashzd@gmail.com")
    monkeypatch.setenv("APP_ENV", "local")
    from pulse_server.config import get_settings

    get_settings.cache_clear()
    assert email_to_user_key("khashzd@gmail.com") == "khash"
    assert email_to_user_key("other@example.com") == "khash"  # single-user today
