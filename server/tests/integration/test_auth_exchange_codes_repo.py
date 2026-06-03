"""Integration tests for ``AuthExchangeCodesRepository``.

Exercises the single-use OAuth PKCE exchange-code store against a real
Postgres: create + ``consume`` (returns the row once, ``None`` on replay),
``consume`` on an unknown hash, and ``purge_expired`` (deletes only rows past
their expiry and returns the count). Each test truncates the
``auth_exchange_codes`` table via the module-level ``db`` pool. Integration
test: hits a real Postgres via ``TEST_DATABASE_URL``.
"""

from __future__ import annotations

import hashlib
import os
import uuid
from datetime import datetime, timedelta, timezone

import pytest
import pytest_asyncio
import sqlalchemy as sa

from pulse_server import db
from pulse_server.repositories.auth_exchange_codes import AuthExchangeCodesRepository

pytestmark = pytest.mark.integration


@pytest_asyncio.fixture
async def session():
    """Bootstrap the module-level DB pool, truncate ``auth_exchange_codes``, and yield a session.

    **Outputs:**
    - AsyncSession: open async session over the integration database; the pool
      is closed on teardown. Skips when ``TEST_DATABASE_URL`` is unset.
    """
    if not os.environ.get("TEST_DATABASE_URL"):
        pytest.skip("TEST_DATABASE_URL not set")
    await db.init_pool(os.environ["TEST_DATABASE_URL"])
    await db.bootstrap_schema()
    async with db.get_session() as s:
        await s.execute(sa.text("truncate auth_exchange_codes"))
        await s.commit()
        yield s
    await db.close_pool()


def _hash(code: str) -> bytes:
    """Compute the binary sha256 digest used as the exchange-code lookup key.

    **Inputs:**
    - code (str): The opaque one-time authorization code in clear text.

    **Outputs:**
    - bytes: 32-byte sha256 digest of the code.
    """
    return hashlib.sha256(code.encode()).digest()


async def test_create_then_consume_round_trip(session) -> None:
    """``create`` stores a code and ``consume`` returns its email/challenge/expiry exactly once."""
    repo = AuthExchangeCodesRepository(session)
    now = datetime.now(timezone.utc)
    expires = now + timedelta(minutes=2)
    h = _hash(f"code-{uuid.uuid4()}")

    await repo.create(
        code_hash=h,
        email="user@example.com",
        code_challenge="challenge-abc",
        now=now,
        expires_at=expires,
    )
    await session.commit()

    row = await repo.consume(h)
    await session.commit()
    assert row is not None
    assert row["email"] == "user@example.com"
    assert row["code_challenge"] == "challenge-abc"
    assert row["expires_at"] == expires

    # Single-use: a replay finds nothing.
    replay = await repo.consume(h)
    await session.commit()
    assert replay is None


async def test_consume_unknown_code_returns_none(session) -> None:
    """``consume`` on a hash that was never stored returns ``None``."""
    repo = AuthExchangeCodesRepository(session)
    assert await repo.consume(_hash(f"never-{uuid.uuid4()}")) is None


async def test_purge_expired_removes_only_expired_rows(session) -> None:
    """``purge_expired`` deletes rows whose expiry has passed and leaves live ones intact."""
    repo = AuthExchangeCodesRepository(session)
    now = datetime.now(timezone.utc)
    expired_hash = _hash(f"expired-{uuid.uuid4()}")
    live_hash = _hash(f"live-{uuid.uuid4()}")

    await repo.create(
        code_hash=expired_hash,
        email="a@example.com",
        code_challenge="c1",
        now=now - timedelta(minutes=10),
        expires_at=now - timedelta(minutes=5),
    )
    await repo.create(
        code_hash=live_hash,
        email="b@example.com",
        code_challenge="c2",
        now=now,
        expires_at=now + timedelta(minutes=5),
    )
    await session.commit()

    deleted = await repo.purge_expired(now)
    await session.commit()
    assert deleted == 1

    # The expired row is gone; the live row still consumes successfully.
    assert await repo.consume(expired_hash) is None
    live = await repo.consume(live_hash)
    await session.commit()
    assert live is not None
    assert live["email"] == "b@example.com"
