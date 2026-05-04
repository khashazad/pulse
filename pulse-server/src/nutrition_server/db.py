from __future__ import annotations

import socket
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator
from urllib.parse import urlparse, urlunparse

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine

_engine: AsyncEngine | None = None
_session_factory: async_sessionmaker[AsyncSession] | None = None


# Summary: Adds `hostaddr=<IPv4>` to the connection URL when the host has IPv4 records.
# Parameters:
# - database_url (str): SQLAlchemy-style PostgreSQL connection URL.
# Returns:
# - str: Same URL with a hostaddr query param appended; unchanged when IPv4 resolution fails.
# Raises/Throws:
# - None: Resolution failures fall through; libpq will surface a clearer error if connecting fails.
def _force_ipv4(database_url: str) -> str:
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


# Summary: Converts an application database URL into a SQLAlchemy async driver URL.
# Parameters:
# - database_url (str): Application database URL from environment configuration.
# Returns:
# - str: SQLAlchemy-compatible URL preserving host, auth, and database path.
# Raises/Throws:
# - None: Unsupported schemes are returned unchanged for caller-level validation.
def to_sqlalchemy_url(database_url: str) -> str:
    if database_url.startswith("postgresql+"):
        return database_url
    if database_url.startswith("postgres://"):
        return database_url.replace("postgres://", "postgresql+psycopg://", 1)
    if database_url.startswith("postgresql://"):
        return database_url.replace("postgresql://", "postgresql+psycopg://", 1)
    return database_url


# Summary: Splits a SQL script into executable statements using semicolon terminators.
# Parameters:
# - sql_script (str): Raw SQL text possibly containing multiple statements.
# Returns:
# - list[str]: Ordered list of executable SQL statements with surrounding whitespace trimmed.
# Raises/Throws:
# - None: This splitter assumes schema SQL does not contain semicolons inside quoted string literals.
def _split_sql_statements(sql_script: str) -> list[str]:
    statements: list[str] = []
    chunks = sql_script.split(";")
    for chunk in chunks:
        statement = chunk.strip()
        if statement:
            statements.append(statement)
    return statements


# Summary: Initializes the shared SQLAlchemy async engine and session factory.
# Parameters:
# - database_url (str): PostgreSQL connection string used by the application.
# Returns:
# - None: Initializes module-level engine and session-factory state.
# Raises/Throws:
# - sqlalchemy.exc.SQLAlchemyError: Raised when engine initialization or connectivity check fails.
async def init_pool(database_url: str) -> None:
    global _engine
    global _session_factory

    sqlalchemy_url = _force_ipv4(to_sqlalchemy_url(database_url))
    _engine = create_async_engine(sqlalchemy_url, pool_pre_ping=True)
    _session_factory = async_sessionmaker(_engine, expire_on_commit=False)

    async with _engine.connect() as conn:
        await conn.execute(text("SELECT 1"))


# Summary: Closes and clears the shared SQLAlchemy engine and session factory.
# Parameters:
# - None: Operates on module-level engine and session-factory state.
# Returns:
# - None: Engine resources are disposed and global references are reset.
# Raises/Throws:
# - sqlalchemy.exc.SQLAlchemyError: Raised when engine disposal fails.
async def close_pool() -> None:
    global _engine
    global _session_factory

    if _engine is not None:
        await _engine.dispose()
        _engine = None
    _session_factory = None


# Summary: Executes schema bootstrap SQL against the active database connection.
# Parameters:
# - None: Loads schema from the repository-local `schema.sql` file.
# Returns:
# - None: Executes schema statements in the current database.
# Raises/Throws:
# - RuntimeError: Raised when called before the SQLAlchemy engine is initialized.
# - OSError: Raised when the schema file cannot be read.
# - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
async def bootstrap_schema() -> None:
    if _engine is None:
        raise RuntimeError("Database pool not initialized")

    schema_path = Path(__file__).resolve().parents[2] / "schema.sql"
    sql_script = schema_path.read_text()
    statements = _split_sql_statements(sql_script)
    async with _engine.begin() as conn:
        for statement in statements:
            await conn.execute(text(statement))


# Summary: Yields an async SQLAlchemy session from the shared session factory.
# Parameters:
# - None: Uses the initialized module-level async session factory.
# Returns:
# - AsyncIterator[AsyncSession]: Context-managed SQLAlchemy async session.
# Raises/Throws:
# - RuntimeError: Raised when the database session factory has not been initialized.
# - sqlalchemy.exc.SQLAlchemyError: Raised when session acquisition fails.
@asynccontextmanager
async def get_session() -> AsyncIterator[AsyncSession]:
    if _session_factory is None:
        raise RuntimeError("Database pool not initialized")
    async with _session_factory() as session:
        yield session


# Summary: Provides an async session dependency for FastAPI route handlers.
# Parameters:
# - None: Delegates to the shared SQLAlchemy session factory context manager.
# Returns:
# - AsyncIterator[AsyncSession]: Request-scoped SQLAlchemy async session.
# Raises/Throws:
# - RuntimeError: Raised when the database session factory has not been initialized.
# - sqlalchemy.exc.SQLAlchemyError: Raised when session lifecycle operations fail.
async def get_session_dependency() -> AsyncIterator[AsyncSession]:
    async with get_session() as session:
        yield session


# Summary: Opens a transaction boundary on an existing SQLAlchemy async session.
# Parameters:
# - session (AsyncSession): Active SQLAlchemy session participating in repository operations.
# Returns:
# - AsyncIterator[AsyncSession]: Session bound to an open transaction until context exits.
# Raises/Throws:
# - sqlalchemy.exc.SQLAlchemyError: Raised when begin/commit/rollback fails.
@asynccontextmanager
async def transaction(session: AsyncSession) -> AsyncIterator[AsyncSession]:
    async with session.begin():
        yield session
