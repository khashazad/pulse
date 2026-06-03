"""Shared setup for the integration suite.

Guarantees the Postgres schema defined in ``schema.sql`` exists before any
integration test runs. Several integration modules (e.g. ``test_aliases.py``)
only *truncate* their tables and assume the schema already exists; without this
fixture they depend on pytest happening to run a bootstrap-running module first,
which fails on a fresh database or when collection order changes.
"""

from __future__ import annotations

import os

import pytest_asyncio

from pulse_server import db


@pytest_asyncio.fixture(scope="session", autouse=True)
async def _bootstrap_integration_schema():
    """Bootstrap ``schema.sql`` once per test session against ``TEST_DATABASE_URL``.

    The pool is opened only long enough to run the idempotent bootstrap and then
    closed, leaving per-test fixtures free to manage their own engines/pools as
    they do today.

    **Outputs:**
    - None: yields control to the session after the schema is ensured. When
      ``TEST_DATABASE_URL`` is unset, integration tests skip themselves, so this
      fixture becomes a no-op.

    **Raises/Throws:**
    - sqlalchemy.exc.SQLAlchemyError: Propagated if connecting to the database or
      running the bootstrap statements fails.
    """
    test_db_url = os.environ.get("TEST_DATABASE_URL")
    if test_db_url is None:
        yield
        return
    await db.init_pool(test_db_url)
    try:
        await db.bootstrap_schema()
    finally:
        await db.close_pool()
    yield
