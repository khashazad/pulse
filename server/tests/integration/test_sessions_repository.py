"""Integration tests for ``SessionsRepository``.

Exercises the opaque-Bearer session store: create + lookup-by-hash, sliding TTL
extension on ``slide``, and idempotent deletion (returns delete count, zero on
second call). Each test truncates the ``sessions`` table via the module-level
``db`` pool. Integration test: hits a real Postgres via ``TEST_DATABASE_URL``.
"""

from __future__ import annotations

import hashlib
import os
from datetime import UTC, datetime, timedelta

import pytest
import sqlalchemy as sa

pytestmark = pytest.mark.integration


@pytest.fixture
async def session():
    """Bootstrap the module-level DB pool, truncate ``sessions``, and yield a session.

    **Outputs:**
    - ``AsyncSession``: open async session over the integration database.
    """
    if not os.environ.get("TEST_DATABASE_URL"):
        pytest.skip("TEST_DATABASE_URL not set")
    from pulse_server import db

    await db.init_pool(os.environ["TEST_DATABASE_URL"])
    await db.bootstrap_schema()
    async with db.get_session() as s:
        await s.execute(sa.text("truncate sessions"))
        await s.commit()
        yield s
    await db.close_pool()


def _hash(token: str) -> bytes:
    """Compute the binary ``sha256`` hash used as the session lookup key.

    **Inputs:**
    - token (str): the opaque session token in clear text.

    **Outputs:**
    - bytes: 32-byte ``sha256`` digest of the token.
    """
    return hashlib.sha256(token.encode()).digest()


async def test_create_and_lookup(session):
    """``create`` then ``get`` round-trips the email and expiry for a hashed token."""
    from pulse_server.repositories.sessions import SessionsRepository

    repo = SessionsRepository(session)
    now = datetime.now(UTC)
    expires = now + timedelta(days=7)
    await repo.create(
        token_hash=_hash("tok"), email="user@example.com", now=now, expires_at=expires
    )
    await session.commit()

    row = await repo.get(_hash("tok"))
    assert row is not None
    assert row["email"] == "user@example.com"
    assert row["expires_at"] == expires


async def test_slide_extends_expiry(session):
    """``slide`` advances ``last_used_at`` and ``expires_at`` for an existing token."""
    from pulse_server.repositories.sessions import SessionsRepository

    repo = SessionsRepository(session)
    now = datetime.now(UTC)
    h = _hash("tok2")
    await repo.create(
        token_hash=h, email="u@example.com", now=now, expires_at=now + timedelta(days=1)
    )
    await session.commit()

    new_now = now + timedelta(hours=1)
    new_expires = new_now + timedelta(days=7)
    updated = await repo.slide(token_hash=h, now=new_now, new_expires_at=new_expires)
    await session.commit()
    assert updated == 1

    row = await repo.get(h)
    assert row["last_used_at"] == new_now
    assert row["expires_at"] == new_expires


async def test_delete_returns_count(session):
    """``delete`` returns 1 for an existing token and 0 on a repeated delete of the same hash."""
    from pulse_server.repositories.sessions import SessionsRepository

    repo = SessionsRepository(session)
    now = datetime.now(UTC)
    h = _hash("tok3")
    await repo.create(
        token_hash=h, email="u@example.com", now=now, expires_at=now + timedelta(days=1)
    )
    await session.commit()

    count = await repo.delete(h)
    await session.commit()
    assert count == 1

    again = await repo.delete(h)
    await session.commit()
    assert again == 0
