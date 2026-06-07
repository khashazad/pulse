"""Persistent OAuth-state storage for the MCP layer.

fastmcp's ``OAuthProxy`` (which ``GitHubProvider`` builds on) stores dynamic
client registrations and upstream GitHub tokens in ``client_storage``. Its
default is an encrypted file store on container-local disk — state Railway
wipes on every deploy, forcing claude.ai to re-register, re-OAuth, and re-ask
for tool permissions. This module builds the durable replacement: a
Fernet-encrypted ``PostgreSQLStore`` living in the same Postgres as the app
data (library-managed ``mcp_oauth_kv`` table; deliberately NOT in
``schema.sql``).

Two deployment quirks are handled by :class:`PinnedPostgreSQLStore`:

- The Supabase pooler hostname returns A and AAAA records, but Railway
  containers have no IPv6 — connect via resolved IPv4 (mirrors ``db._force_ipv4``).
- asyncpg's named prepared statements break against Supabase's
  transaction-mode pooler — ``statement_cache_size=0`` disables the cache and
  is harmless on session-mode/direct connections. This must be a connect
  kwarg: asyncpg routes unknown DSN query params into ``server_settings``.
"""

from __future__ import annotations

import asyncio
import socket
from typing import TYPE_CHECKING
from urllib.parse import urlparse

import asyncpg
from key_value.aio.stores.postgresql import PostgreSQLStore
from key_value.aio.wrappers.encryption import FernetEncryptionWrapper

if TYPE_CHECKING:
    from key_value.aio.protocols.key_value import AsyncKeyValue

    from pulse_server.config import Settings

# Library-managed key/value table holding encrypted OAuth proxy state
# (client registrations, upstream token sets). Auto-created by
# PostgreSQLStore on first use; intentionally absent from schema.sql.
MCP_OAUTH_KV_TABLE = "mcp_oauth_kv"

# Fixed salt for deriving the Fernet key from MCP_STORAGE_ENCRYPTION_KEY.
# Changing it (or the key) invalidates stored state — clients simply
# re-register on the next connect, so rotation is safe but costs one re-auth.
STORAGE_ENCRYPTION_SALT = "pulse-mcp-oauth-storage"

# The store handed to the OAuth proxy by the last `build_client_storage` call,
# kept so `aclose_client_storage` can drain its asyncpg pool at shutdown.
# Single-assignment in production (one build at import time). Tests that build
# stores must close any pool they open on their own event loop (and unit-test
# builds that never touch the DB are safely abandoned) — a store left here
# with a pool bound to a finished test's loop would make a later lifespan
# shutdown fail with "Event loop is closed".
_active_store: PinnedPostgreSQLStore | None = None


def normalize_asyncpg_url(database_url: str) -> str:
    """Strip a SQLAlchemy driver suffix so the URL is consumable by asyncpg.

    ``postgresql+psycopg://...`` → ``postgresql://...``; plain ``postgresql://``
    and ``postgres://`` URLs pass through unchanged (asyncpg accepts both).

    **Inputs:**
    - database_url (str): Application database URL from configuration.

    **Outputs:**
    - str: URL safe to hand to ``asyncpg.create_pool``.
    """
    if database_url.startswith("postgresql+"):
        # Discard the "postgresql+<driver>" prefix; keep the DSN body after "://".
        _, rest = database_url.split("://", 1)
        return f"postgresql://{rest}"
    return database_url


def resolve_ipv4(database_url: str) -> str | None:
    """Resolve the URL's host to an IPv4 address, returning None on failure.

    Mirrors ``db._force_ipv4``: the Supabase pooler host publishes AAAA records
    that Railway containers cannot route, so callers pin the connection to the
    resolved A record. Resolution failures fall through so asyncpg can surface
    a clearer connect-time error.

    **Inputs:**
    - database_url (str): PostgreSQL connection URL.

    **Outputs:**
    - str | None: First resolved IPv4 address, or None when the URL has no
      host or IPv4 resolution fails.
    """
    parsed = urlparse(database_url)
    host = parsed.hostname
    if not host:
        return None
    try:
        info = socket.getaddrinfo(host, parsed.port or 5432, socket.AF_INET, socket.SOCK_STREAM)
    except socket.gaierror:
        return None
    # getaddrinfo raises gaierror rather than returning an empty list, so the
    # first result always exists here. AF_INET sockaddrs are (host, port) —
    # str() narrows the `str | int` union for the type checker.
    return str(info[0][4][0])


class PinnedPostgreSQLStore(PostgreSQLStore):
    """``PostgreSQLStore`` whose pool is pinned for Railway → Supabase.

    Overrides pool creation to (a) connect via resolved IPv4 (Railway has no
    IPv6 route to the pooler's AAAA records), (b) disable asyncpg's named
    prepared-statement cache (incompatible with Supabase's transaction-mode
    pooler), and (c) keep the pool small — Supabase session mode maps each
    client connection to a dedicated backend, and the single-user MCP layer
    never needs asyncpg's default of 10. Also sweeps expired rows once per
    process: the library filters them on read but never deletes them, so
    without the sweep abandoned auth-flow rows would accumulate forever.
    Must be constructed with ``url=`` — the host/port/user kwargs of the base
    class are not supported here.
    """

    async def _create_pool(self) -> asyncpg.Pool:
        """Create the asyncpg pool with IPv4 pinning and statement cache off.

        Resolves the host to an IPv4 address off the event loop (via
        ``asyncio.to_thread``) so a slow DNS lookup does not stall the caller.

        **Outputs:**
        - asyncpg.Pool: Connected pool for the configured URL.

        **Exceptions:**
        - RuntimeError: The store was constructed without ``url=``.
        - asyncpg.PostgresError / OSError: Propagated when connecting fails.
        """
        if self._url is None:
            raise RuntimeError("PinnedPostgreSQLStore requires url=")
        # Small pool: asyncpg defaults to min/max 10, which would hold 10 idle
        # backends on Supabase's session pooler alongside the app's psycopg
        # pool — far beyond what single-user OAuth traffic needs.
        kwargs: dict = {
            "dsn": self._url,
            "statement_cache_size": 0,
            "min_size": 1,
            "max_size": 3,
        }
        # DNS via a worker thread: socket.getaddrinfo is blocking, and this
        # async method runs on the event loop (a slow resolver would stall it).
        ipv4 = await asyncio.to_thread(resolve_ipv4, self._url)
        if ipv4 is not None:
            # An explicit host kwarg makes asyncpg skip DSN hostspec parsing
            # entirely — which also drops the DSN's port — so pin both. Auth
            # and database still come from the DSN. TLS stays usable because
            # asyncpg's default ssl='prefer' does not verify hostnames.
            kwargs["host"] = ipv4
            kwargs["port"] = urlparse(self._url).port or 5432
        pool = await asyncpg.create_pool(**kwargs)
        if pool is None:  # pragma: no cover - asyncpg returns a pool or raises
            raise RuntimeError("asyncpg.create_pool returned None")
        return pool

    async def _setup(self) -> None:
        """Run the base setup (pool + table), then sweep expired rows once.

        The py-key-value library checks ``expires_at`` on read but never
        deletes expired rows, and fastmcp has no sweeper — so abandoned
        OAuth-flow rows (timed-out transactions, unused JTI mappings) would
        otherwise accumulate indefinitely. Running the sweep here piggybacks
        on the base class's once-per-process setup lock and guarantees the
        table already exists.

        **Outputs:**
        - None: Side effect only (pool/table setup + expired-row deletion).

        **Exceptions:**
        - asyncpg.PostgresError: Propagated when setup or the sweep fails.
        """
        await super()._setup()
        pool = self._pool
        if pool is None:  # pragma: no cover - base _setup always sets the pool
            raise RuntimeError("PostgreSQLStore._setup did not create a pool")
        # _table_name is validated against SQL injection by the base __init__.
        await pool.execute(
            f"DELETE FROM {self._table_name} WHERE expires_at IS NOT NULL AND expires_at < now()"
        )


def build_client_storage(settings: Settings) -> AsyncKeyValue | None:
    """Build the encrypted Postgres-backed ``client_storage`` for the OAuth proxy.

    Opt-in via ``MCP_STORAGE_ENCRYPTION_KEY``: when unset (local dev) this
    returns None and fastmcp keeps its default disk store. When set, OAuth
    state lands Fernet-encrypted in the app database and survives redeploys,
    so the claude.ai connector keeps its registration and tokens.

    **Inputs:**
    - settings (Settings): Application settings carrying ``database_url`` and
      ``mcp_storage_encryption_key``.

    **Outputs:**
    - AsyncKeyValue | None: Encrypted persistent store, or None when the
      feature is not configured.
    """
    global _active_store
    if not settings.mcp_storage_encryption_key:
        return None
    store = PinnedPostgreSQLStore(
        url=normalize_asyncpg_url(settings.database_url),
        table_name=MCP_OAUTH_KV_TABLE,
    )
    # Track the inner store so the app lifespan can close its asyncpg pool on
    # shutdown — fastmcp never closes client_storage, and the Fernet wrapper
    # doesn't delegate context management to the wrapped store.
    _active_store = store
    return FernetEncryptionWrapper(
        key_value=store,
        source_material=settings.mcp_storage_encryption_key,
        salt=STORAGE_ENCRYPTION_SALT,
        # A rotated/wrong key degrades to a cache miss (client re-registers,
        # one re-auth) instead of a hard failure — matches fastmcp's default.
        raise_on_decryption_error=False,
    )


async def aclose_client_storage() -> None:
    """Close the most recently built store's asyncpg pool, if it ever opened.

    Called from the app lifespan on shutdown so the pool sends Postgres a
    clean Terminate instead of relying on the container's death to RST the
    sockets. ``BaseContextManagerStore.close`` no-ops when the store was
    never used (no pool was created), so calling this unconditionally is safe.

    **Outputs:**
    - None: Side effect only; resets the tracked store.
    """
    global _active_store
    store = _active_store
    _active_store = None
    if store is not None:
        await store.close()
