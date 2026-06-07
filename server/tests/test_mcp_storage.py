"""Tests for `pulse_server.mcp.storage` — the persistent OAuth-state store.

Covers the build gate (env-key opt-in), the encryption wrapping, the asyncpg
URL normalization, and the Railway/Supabase pool pinning (IPv4 + disabled
statement cache).
"""

from __future__ import annotations

import pytest

from pulse_server.config import Settings

_BASE_KWARGS = {"database_url": "postgresql://localhost/test", "usda_api_key": "x"}


def _settings(**overrides) -> Settings:
    return Settings(_env_file=None, **{**_BASE_KWARGS, **overrides})


def test_build_client_storage_returns_none_without_key():
    """No MCP_STORAGE_ENCRYPTION_KEY → None, so fastmcp keeps its default store."""
    from pulse_server.mcp.storage import build_client_storage

    assert build_client_storage(_settings()) is None


def test_build_client_storage_wraps_encrypted_postgres_store():
    """With a key set, the store is a Fernet wrapper around the pinned PG store."""
    from key_value.aio.wrappers.encryption import FernetEncryptionWrapper

    from pulse_server.mcp.storage import (
        MCP_OAUTH_KV_TABLE,
        PinnedPostgreSQLStore,
        build_client_storage,
    )

    storage = build_client_storage(_settings(mcp_storage_encryption_key="e" * 40))
    assert isinstance(storage, FernetEncryptionWrapper)
    assert isinstance(storage.key_value, PinnedPostgreSQLStore)
    assert storage.key_value._table_name == MCP_OAUTH_KV_TABLE


def test_normalize_asyncpg_url_strips_sqlalchemy_driver():
    """SQLAlchemy-style driver suffixes are stripped for asyncpg consumption."""
    from pulse_server.mcp.storage import normalize_asyncpg_url

    assert (
        normalize_asyncpg_url("postgresql+psycopg://u:p@h:5432/db")
        == "postgresql://u:p@h:5432/db"
    )
    assert normalize_asyncpg_url("postgresql://u:p@h/db") == "postgresql://u:p@h/db"
    assert normalize_asyncpg_url("postgres://u:p@h/db") == "postgres://u:p@h/db"


def test_resolve_ipv4_handles_unresolvable_host():
    """DNS failures return None instead of raising."""
    from pulse_server.mcp.storage import resolve_ipv4

    assert resolve_ipv4("postgresql://u:p@nonexistent.invalid:5432/db") is None


def test_resolve_ipv4_resolves_localhost():
    """A resolvable host returns its IPv4 address."""
    from pulse_server.mcp.storage import resolve_ipv4

    assert resolve_ipv4("postgresql://u:p@localhost:5432/db") == "127.0.0.1"


@pytest.mark.asyncio
async def test_create_pool_pins_ipv4_and_disables_statement_cache(monkeypatch):
    """The pool connects via resolved IPv4 with asyncpg's statement cache off.

    statement_cache_size=0 is required for Supabase's transaction-mode pooler;
    the IPv4 pin mirrors db.py's psycopg fix for Railway's lack of IPv6.
    """
    import asyncpg

    from pulse_server.mcp import storage as storage_mod

    captured: dict = {}

    async def fake_create_pool(**kwargs):
        captured.update(kwargs)
        return object()

    monkeypatch.setattr(asyncpg, "create_pool", fake_create_pool)
    monkeypatch.setattr(storage_mod, "resolve_ipv4", lambda url: "1.2.3.4")

    store = storage_mod.PinnedPostgreSQLStore(url="postgresql://u:p@db.example.com:6543/postgres")
    await store._create_pool()

    assert captured == {
        "dsn": "postgresql://u:p@db.example.com:6543/postgres",
        "statement_cache_size": 0,
        "host": "1.2.3.4",
        "port": 6543,
    }


@pytest.mark.asyncio
async def test_create_pool_omits_host_when_ipv4_unresolvable(monkeypatch):
    """When IPv4 resolution fails, the DSN host is used as-is (no host kwarg)."""
    import asyncpg

    from pulse_server.mcp import storage as storage_mod

    captured: dict = {}

    async def fake_create_pool(**kwargs):
        captured.update(kwargs)
        return object()

    monkeypatch.setattr(asyncpg, "create_pool", fake_create_pool)
    monkeypatch.setattr(storage_mod, "resolve_ipv4", lambda url: None)

    store = storage_mod.PinnedPostgreSQLStore(url="postgresql://u:p@db.example.com:6543/postgres")
    await store._create_pool()

    assert captured == {
        "dsn": "postgresql://u:p@db.example.com:6543/postgres",
        "statement_cache_size": 0,
    }
