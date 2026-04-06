from __future__ import annotations

from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator

import psycopg
import psycopg.rows
from psycopg_pool import AsyncConnectionPool

_pool: AsyncConnectionPool | None = None


# Summary: Initializes the shared async database connection pool.
# Parameters:
# - database_url (str): PostgreSQL connection string used by psycopg.
# Returns:
# - None: Initializes module-level pool state.
# Raises/Throws:
# - psycopg.Error: Raised when the pool cannot be opened.
async def init_pool(database_url: str) -> None:
    global _pool
    _pool = AsyncConnectionPool(conninfo=database_url, min_size=1, max_size=5, open=False)
    await _pool.open()


# Summary: Closes and clears the shared async database connection pool.
# Parameters:
# - None: Operates on module-level pool state.
# Returns:
# - None: The pool reference is reset after closing.
# Raises/Throws:
# - psycopg.Error: Raised when pool shutdown fails.
async def close_pool() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


# Summary: Executes schema bootstrap SQL against the active database connection.
# Parameters:
# - None: Loads schema from the repository-local `schema.sql` file.
# Returns:
# - None: Executes schema statements in the current database.
# Raises/Throws:
# - RuntimeError: Raised when called before the pool is initialized.
# - OSError: Raised when the schema file cannot be read.
# - psycopg.Error: Raised when SQL execution fails.
async def bootstrap_schema() -> None:
    schema_path = Path(__file__).resolve().parents[2] / "schema.sql"
    sql = schema_path.read_text()
    async with get_conn() as conn:
        await conn.execute(sql)


# Summary: Yields an async psycopg connection from the shared pool.
# Parameters:
# - None: Uses the initialized module-level connection pool.
# Returns:
# - AsyncIterator[psycopg.AsyncConnection]: Context-managed async database connection.
# Raises/Throws:
# - RuntimeError: Raised when the database pool has not been initialized.
# - psycopg.Error: Raised when acquiring a connection fails.
@asynccontextmanager
async def get_conn() -> AsyncIterator[psycopg.AsyncConnection]:
    if _pool is None:
        raise RuntimeError("Database pool not initialized")
    async with _pool.connection() as conn:
        conn.row_factory = psycopg.rows.dict_row
        yield conn
