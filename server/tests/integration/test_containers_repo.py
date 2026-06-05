"""Integration tests for ``ContainersRepository``.

Covers create / get / list / update / delete on the ``containers`` table plus
the photo bytea side-channel: ``set_photo`` / ``get_photo`` (full + thumb) /
``clear_photo``, the user-scoping invariant on listing, the unique normalized
name constraint, and the rule that list rows must NOT include the ``photo`` or
``photo_thumb`` BYTEA columns. Integration test: hits a real Postgres via
``TEST_DATABASE_URL``.
"""

from __future__ import annotations

import os
from datetime import UTC
from datetime import datetime as DateTimeValue

import pytest
import pytest_asyncio
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from pulse_server.db import to_sqlalchemy_url, transaction
from pulse_server.repositories.containers import ContainersRepository

pytestmark = pytest.mark.integration


def _integration_database_url() -> str:
    """Resolve the SQLAlchemy URL for the integration database, skipping if unset.

    **Outputs:**
    - str: SQLAlchemy-async URL derived from ``TEST_DATABASE_URL``.

    **Exceptions:**
    - ``pytest.skip.Exception``: Raised via ``pytest.skip`` when ``TEST_DATABASE_URL`` is not set.
    """
    raw_url = os.getenv("TEST_DATABASE_URL")
    if raw_url is None:
        pytest.skip("Set TEST_DATABASE_URL to run integration tests")
    return to_sqlalchemy_url(raw_url)


async def _truncate(engine) -> None:
    """Truncate the ``containers`` table, restarting identity sequences.

    **Inputs:**
    - engine: SQLAlchemy async engine bound to the integration database.
    """
    async with engine.begin() as conn:
        await conn.exec_driver_sql("TRUNCATE TABLE containers RESTART IDENTITY CASCADE")


@pytest_asyncio.fixture
async def session() -> AsyncSession:
    """Per-test async session with a freshly-truncated ``containers`` table.

    **Outputs:**
    - ``AsyncSession``: open session, disposed of with the engine on teardown.
    """
    engine = create_async_engine(_integration_database_url())
    await _truncate(engine)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as s:
        yield s
    await engine.dispose()


def _now() -> DateTimeValue:
    """Return the current UTC timestamp for ``created_at`` / ``updated_at`` fields.

    **Outputs:**
    - datetime: timezone-aware UTC ``datetime``.
    """
    return DateTimeValue.now(tz=UTC)


@pytest.mark.asyncio
async def test_create_then_get(session: AsyncSession) -> None:
    """``create`` returns a row whose fields round-trip through ``get_by_id`` without leaking photo blobs."""
    repo = ContainersRepository(session)
    async with transaction(session):
        row = await repo.create(
            user_key="khash",
            name="Big Pyrex",
            normalized_name="big pyrex",
            tare_weight_g=412.0,
            now=_now(),
        )
    assert row["name"] == "Big Pyrex"
    assert float(row["tare_weight_g"]) == 412.0
    assert "photo" not in row
    assert row["has_photo"] is False

    got = await repo.get_by_id(row["id"], "khash")
    assert got is not None and got["id"] == row["id"]


@pytest.mark.asyncio
async def test_duplicate_normalized_name_raises(session: AsyncSession) -> None:
    """A second ``create`` with the same ``normalized_name`` for the same user raises ``IntegrityError``."""
    repo = ContainersRepository(session)
    async with transaction(session):
        await repo.create("khash", "Big Pyrex", "big pyrex", 412.0, _now())
    with pytest.raises(IntegrityError):
        async with transaction(session):
            await repo.create("khash", "Big Pyrex", "big pyrex", 500.0, _now())


@pytest.mark.asyncio
async def test_list_for_user_excludes_other_users(session: AsyncSession) -> None:
    """``list_for_user`` returns only rows owned by the requested ``user_key``."""
    repo = ContainersRepository(session)
    async with transaction(session):
        await repo.create("khash", "A", "a", 100.0, _now())
        await repo.create("other", "B", "b", 200.0, _now())
    rows = await repo.list_for_user("khash")
    assert len(rows) == 1 and rows[0]["name"] == "A"


@pytest.mark.asyncio
async def test_list_does_not_select_blob_columns(session: AsyncSession) -> None:
    """``list_for_user`` rows omit ``photo`` / ``photo_thumb`` BYTEA columns even when set."""
    repo = ContainersRepository(session)
    async with transaction(session):
        await repo.create("khash", "A", "a", 100.0, _now())
        # Simulate a photo on the row to ensure list still excludes it.
        await repo.set_photo(
            container_id=(await repo.list_for_user("khash"))[0]["id"],
            user_key="khash",
            photo=b"\xff\xd8\xff",
            photo_thumb=b"\xff\xd8\xff",
            mime="image/jpeg",
            now=_now(),
        )
    rows = await repo.list_for_user("khash")
    assert "photo" not in rows[0]
    assert "photo_thumb" not in rows[0]
    assert rows[0]["has_photo"] is True


@pytest.mark.asyncio
async def test_update_fields(session: AsyncSession) -> None:
    """``update_fields`` applies a partial column update and returns the new row."""
    repo = ContainersRepository(session)
    async with transaction(session):
        row = await repo.create("khash", "A", "a", 100.0, _now())
    async with transaction(session):
        updated = await repo.update_fields(
            row["id"], "khash", {"name": "B", "normalized_name": "b"}, _now()
        )
    assert updated is not None
    assert updated["name"] == "B" and updated["normalized_name"] == "b"


@pytest.mark.asyncio
async def test_delete(session: AsyncSession) -> None:
    """``delete`` removes a row and subsequent ``get_by_id`` returns ``None``."""
    repo = ContainersRepository(session)
    async with transaction(session):
        row = await repo.create("khash", "A", "a", 100.0, _now())
    async with transaction(session):
        ok = await repo.delete(row["id"], "khash")
    assert ok is True
    assert await repo.get_by_id(row["id"], "khash") is None


@pytest.mark.asyncio
async def test_get_photo_returns_full_or_thumb(session: AsyncSession) -> None:
    """``get_photo`` returns the full or thumbnail bytes plus mime per the ``thumb`` flag."""
    repo = ContainersRepository(session)
    async with transaction(session):
        row = await repo.create("khash", "A", "a", 100.0, _now())
        await repo.set_photo(
            container_id=row["id"],
            user_key="khash",
            photo=b"FULL",
            photo_thumb=b"THUMB",
            mime="image/jpeg",
            now=_now(),
        )
    full = await repo.get_photo(row["id"], "khash", thumb=False)
    thumb = await repo.get_photo(row["id"], "khash", thumb=True)
    assert full == (b"FULL", "image/jpeg")
    assert thumb == (b"THUMB", "image/jpeg")


@pytest.mark.asyncio
async def test_clear_photo(session: AsyncSession) -> None:
    """``clear_photo`` wipes the stored bytes so subsequent ``get_photo`` returns ``None``."""
    repo = ContainersRepository(session)
    async with transaction(session):
        row = await repo.create("khash", "A", "a", 100.0, _now())
        await repo.set_photo(row["id"], "khash", b"X", b"Y", "image/jpeg", _now())
    async with transaction(session):
        await repo.clear_photo(row["id"], "khash", _now())
    assert await repo.get_photo(row["id"], "khash", thumb=False) is None


@pytest.mark.asyncio
async def test_set_then_get_photo_round_trip(session: AsyncSession) -> None:
    """Bytes written by ``set_photo`` come back unchanged through both full and thumb reads."""
    repo = ContainersRepository(session)
    async with transaction(session):
        row = await repo.create("khash", "RT", "rt", 50.0, _now())
        await repo.set_photo(
            row["id"], "khash", b"\x89PNG-FULL", b"\x89PNG-THUMB", "image/jpeg", _now()
        )
    full = await repo.get_photo(row["id"], "khash", thumb=False)
    thumb = await repo.get_photo(row["id"], "khash", thumb=True)
    assert full == (b"\x89PNG-FULL", "image/jpeg")
    assert thumb == (b"\x89PNG-THUMB", "image/jpeg")
