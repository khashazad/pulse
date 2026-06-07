"""Integration tests for the MCP OAuth-state store against real Postgres.

Verifies the full stack the OAuth proxy will use in production: the
PinnedPostgreSQLStore auto-creates its table, round-trips values through the
Fernet wrapper, and never persists plaintext. Requires TEST_DATABASE_URL.
"""

from __future__ import annotations

import os

import pytest

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        os.environ.get("TEST_DATABASE_URL") is None,
        reason="TEST_DATABASE_URL not set",
    ),
]

SECRET_VALUE = "gho_super-secret-upstream-token"


@pytest.mark.asyncio
async def test_encrypted_roundtrip_and_no_plaintext_at_rest():
    """Values survive a put/get cycle and are unreadable in the raw table."""
    import asyncpg

    from pulse_server.config import Settings
    from pulse_server.mcp.storage import (
        MCP_OAUTH_KV_TABLE,
        build_client_storage,
        normalize_asyncpg_url,
    )

    test_db_url = os.environ["TEST_DATABASE_URL"]
    settings = Settings(
        _env_file=None,
        database_url=test_db_url,
        usda_api_key="x",
        mcp_storage_encryption_key="integration-test-encryption-key!",
    )
    storage = build_client_storage(settings)
    assert storage is not None

    await storage.put(
        key="client-abc",
        value={"token": SECRET_VALUE},
        collection="mcp-upstream-tokens",
    )
    try:
        # Round-trip through the wrapper decrypts back to the original value.
        loaded = await storage.get(key="client-abc", collection="mcp-upstream-tokens")
        assert loaded == {"token": SECRET_VALUE}

        # Raw row in Postgres must not contain the plaintext secret.
        conn = await asyncpg.connect(normalize_asyncpg_url(test_db_url), statement_cache_size=0)
        try:
            rows = await conn.fetch(f"SELECT value::text AS raw FROM {MCP_OAUTH_KV_TABLE}")
        finally:
            await conn.close()
        assert rows, "expected at least one persisted row"
        assert all(SECRET_VALUE not in row["raw"] for row in rows)
    finally:
        await storage.delete(key="client-abc", collection="mcp-upstream-tokens")
