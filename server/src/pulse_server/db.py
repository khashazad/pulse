"""Database engine, session, and schema-bootstrap utilities.

Owns the module-level SQLAlchemy async engine and session factory used by the
whole application. Provides URL normalization (driver coercion, optional IPv4
pinning), pool init/teardown, idempotent ``schema.sql`` execution split into
dollar-quote-aware statements, and async session helpers — both as a generic
context manager and as a FastAPI dependency.

Every repository acquires its ``AsyncSession`` through helpers defined here;
no other module is permitted to construct engines or session factories.
"""

from __future__ import annotations

import socket
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlparse, urlunparse

from sqlalchemy import text
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

_engine: AsyncEngine | None = None
_session_factory: async_sessionmaker[AsyncSession] | None = None


def _force_ipv4(database_url: str) -> str:
    """Add ``hostaddr=<IPv4>`` to the connection URL when the host resolves over IPv4.

    Resolution failures fall through; libpq will surface a clearer error if
    connecting actually fails.

    **Inputs:**
    - database_url (str): SQLAlchemy-style PostgreSQL connection URL.

    **Outputs:**
    - str: Same URL with a ``hostaddr`` query param appended; unchanged when
      IPv4 resolution fails or one is already present.
    """
    parsed = urlparse(database_url)
    host = parsed.hostname
    if not host:
        return database_url
    try:
        info = socket.getaddrinfo(host, parsed.port or 5432, socket.AF_INET, socket.SOCK_STREAM)
    except socket.gaierror:
        return database_url
    if not info:
        return database_url
    ipv4 = info[0][4][0]
    existing_query = parsed.query
    if "hostaddr=" in existing_query:
        return database_url
    new_query = f"{existing_query}&hostaddr={ipv4}" if existing_query else f"hostaddr={ipv4}"
    return urlunparse(parsed._replace(query=new_query))


def to_sqlalchemy_url(database_url: str) -> str:
    """Convert an application database URL into a SQLAlchemy async driver URL.

    Unsupported schemes are returned unchanged for caller-level validation.

    **Inputs:**
    - database_url (str): Application database URL from environment configuration.

    **Outputs:**
    - str: SQLAlchemy-compatible URL preserving host, auth, and database path.
    """
    if database_url.startswith("postgresql+"):
        return database_url
    if database_url.startswith("postgres://"):
        return database_url.replace("postgres://", "postgresql+psycopg://", 1)
    if database_url.startswith("postgresql://"):
        return database_url.replace("postgresql://", "postgresql+psycopg://", 1)
    return database_url


def _split_sql_statements(sql_script: str) -> list[str]:
    """Split a SQL script into executable statements, respecting quoting and comments.

    Statements are split on top-level semicolons; semicolons inside ``$tag$ ... $tag$``
    blocks (PL/pgSQL bodies), ``--`` line comments, ``/* ... */`` block comments
    (which Postgres allows to nest), and single-quoted string literals (including
    ``''`` escapes) are preserved. Comments are absorbed into the adjacent
    statement's text rather than stripped.

    **Inputs:**
    - sql_script (str): Raw SQL text possibly containing multiple statements,
      dollar-quoted blocks, comments, and string literals.

    **Outputs:**
    - list[str]: Ordered list of executable SQL statements with surrounding
      whitespace trimmed.
    """
    statements: list[str] = []
    buffer: list[str] = []
    current_tag: str | None = None
    i = 0
    length = len(sql_script)

    while i < length:
        if current_tag is None and sql_script.startswith("--", i):
            # Line comment: absorbed into the buffer verbatim (it rides along with
            # the adjacent statement) so a ';' inside never splits.
            end = sql_script.find("\n", i)
            end = length if end == -1 else end
            buffer.append(sql_script[i:end])
            i = end
            continue
        if current_tag is None and sql_script.startswith("/*", i):
            # Block comment (Postgres allows nesting): absorbed verbatim like
            # line comments, so a ';' inside never splits.
            end = i + 2
            depth = 1
            while end < length and depth:
                if sql_script.startswith("/*", end):
                    depth += 1
                    end += 2
                elif sql_script.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            buffer.append(sql_script[i:end])
            i = end
            continue
        if current_tag is None and sql_script[i] == "'":
            # Single-quoted literal: copy verbatim, honouring '' escapes.
            # NOTE: E'...' escape-strings (where \' also escapes the quote) are
            # not supported — do not use them in schema.sql.
            end = i + 1
            while end < length:
                if sql_script[end] == "'":
                    if sql_script.startswith("''", end):
                        end += 2
                        continue
                    break
                end += 1
            end = min(end + 1, length)
            buffer.append(sql_script[i:end])
            i = end
            continue
        if current_tag is None and sql_script[i] == "$":
            end = sql_script.find("$", i + 1)
            if end != -1 and all(c.isalnum() or c == "_" for c in sql_script[i + 1 : end]):
                tag = sql_script[i : end + 1]
                current_tag = tag
                buffer.append(tag)
                i = end + 1
                continue
        if current_tag is not None and sql_script.startswith(current_tag, i):
            buffer.append(current_tag)
            i += len(current_tag)
            current_tag = None
            continue
        if current_tag is None and sql_script[i] == ";":
            statement = "".join(buffer).strip()
            if statement:
                statements.append(statement)
            buffer = []
            i += 1
            continue
        buffer.append(sql_script[i])
        i += 1

    tail = "".join(buffer).strip()
    if tail:
        statements.append(tail)
    return statements


async def init_pool(database_url: str) -> None:
    """Initialize the shared SQLAlchemy async engine and session factory.

    Performs a ``SELECT 1`` round-trip after constructing the engine to fail
    fast on bad credentials or network reachability.

    **Inputs:**
    - database_url (str): PostgreSQL connection string used by the application.

    **Exceptions:**
    - sqlalchemy.exc.SQLAlchemyError: Raised when engine initialization or
      connectivity check fails.
    """
    global _engine
    global _session_factory

    sqlalchemy_url = _force_ipv4(to_sqlalchemy_url(database_url))
    # Explicit pool bounds: Supabase enforces a connection cap, so the defaults
    # (5 + 10 overflow, never recycled) are replaced with a smaller, recycled
    # pool. application_name makes this service identifiable in pg_stat_activity.
    _engine = create_async_engine(
        sqlalchemy_url,
        pool_pre_ping=True,
        pool_size=5,
        max_overflow=5,
        pool_recycle=1800,
        pool_timeout=30,
        connect_args={"application_name": "pulse-server"},
    )
    _session_factory = async_sessionmaker(_engine, expire_on_commit=False)

    async with _engine.connect() as conn:
        await conn.execute(text("SELECT 1"))


async def close_pool() -> None:
    """Close and clear the shared SQLAlchemy engine and session factory.

    Disposes engine resources and resets module-level globals.

    **Exceptions:**
    - sqlalchemy.exc.SQLAlchemyError: Raised when engine disposal fails.
    """
    global _engine
    global _session_factory

    if _engine is not None:
        await _engine.dispose()
        _engine = None
    _session_factory = None


async def bootstrap_schema() -> None:
    """Execute schema bootstrap SQL against the active database connection.

    Reads the repository-local ``schema.sql``, splits it into statements with
    dollar-quote awareness, and runs them inside a single transaction.

    **Exceptions:**
    - RuntimeError: Raised when called before the SQLAlchemy engine is initialized.
    - OSError: Raised when the schema file cannot be read.
    - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    """
    if _engine is None:
        raise RuntimeError("Database pool not initialized")

    # One-shot blocking read during startup/bootstrap only — not on a request path.
    schema_path = Path(__file__).resolve().parents[2] / "schema.sql"  # noqa: ASYNC240
    sql_script = schema_path.read_text()
    statements = _split_sql_statements(sql_script)
    async with _engine.begin() as conn:
        for statement in statements:
            await conn.execute(text(statement))


@asynccontextmanager
async def get_session() -> AsyncIterator[AsyncSession]:
    """Yield an async SQLAlchemy session from the shared session factory.

    **Outputs:**
    - AsyncIterator[AsyncSession]: Context-managed SQLAlchemy async session.

    **Exceptions:**
    - RuntimeError: Raised when the database session factory has not been initialized.
    - sqlalchemy.exc.SQLAlchemyError: Raised when session acquisition fails.
    """
    if _session_factory is None:
        raise RuntimeError("Database pool not initialized")
    async with _session_factory() as session:
        yield session


async def get_session_dependency() -> AsyncIterator[AsyncSession]:
    """Provide an async session dependency for FastAPI route handlers.

    Delegates to :func:`get_session` so request-scoped sessions share the same
    lifecycle semantics as direct callers.

    **Outputs:**
    - AsyncIterator[AsyncSession]: Request-scoped SQLAlchemy async session.

    **Exceptions:**
    - RuntimeError: Raised when the database session factory has not been initialized.
    - sqlalchemy.exc.SQLAlchemyError: Raised when session lifecycle operations fail.
    """
    async with get_session() as session:
        yield session


@asynccontextmanager
async def transaction(session: AsyncSession) -> AsyncIterator[AsyncSession]:
    """Open a transaction boundary on an existing SQLAlchemy async session.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session participating in
      repository operations.

    **Outputs:**
    - AsyncIterator[AsyncSession]: Session bound to an open transaction until
      the context exits.

    **Exceptions:**
    - sqlalchemy.exc.SQLAlchemyError: Raised when begin/commit/rollback fails.
    """
    async with session.begin():
        yield session
