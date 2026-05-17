"""Integration tests for ``ProgressPhotoRepository``.

Covers the ``progress_photos`` upsert + slot semantics: write a JPEG plus
thumbnail per ``(user_key, log_date, slot)``, replace an existing slot in place,
filter list-by-metadata results to an inclusive date range, retrieve full vs.
thumb bytes by flag, and delete a slot. Integration test: hits a real Postgres
via ``TEST_DATABASE_URL``.
"""

from __future__ import annotations

import hashlib
import os
import uuid
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from datetime import timezone as TimezoneValue

import pytest
import pytest_asyncio
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from diet_tracker_server.db import to_sqlalchemy_url, transaction
from diet_tracker_server.repositories.progress_photo import ProgressPhotoRepository

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
    """Truncate the ``progress_photos`` table, restarting identity sequences.

    **Inputs:**
    - engine: SQLAlchemy async engine bound to the integration database.
    """
    async with engine.begin() as conn:
        await conn.exec_driver_sql("TRUNCATE TABLE progress_photos RESTART IDENTITY CASCADE")


@pytest_asyncio.fixture
async def session() -> AsyncSession:
    """Per-test async session with a freshly-truncated ``progress_photos`` table.

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
    return DateTimeValue.now(tz=TimezoneValue.utc)


def _jpeg() -> bytes:
    """Return a fixed byte payload representing a full-size JPEG body.

    **Outputs:**
    - bytes: deterministic fake JPEG bytes used as the ``photo`` argument.
    """
    return b"\xff\xd8\xff\xe0fake-jpeg-bytes"


def _thumb() -> bytes:
    """Return a fixed byte payload representing a thumbnail JPEG body.

    **Outputs:**
    - bytes: deterministic fake JPEG bytes used as the ``photo_thumb`` argument.
    """
    return b"\xff\xd8\xff\xe0fake-thumb"


@pytest.mark.asyncio
async def test_upsert_then_get_round_trip(session: AsyncSession) -> None:
    """``upsert`` persists slot metadata and ``get_photo`` returns the matching full and thumbnail bytes."""
    repo = ProgressPhotoRepository(session)
    user_key = f"test-{uuid.uuid4().hex}"
    sha = hashlib.sha256(_jpeg()).hexdigest()
    async with transaction(session):
        row = await repo.upsert(
            user_key=user_key,
            log_date=DateValue(2026, 5, 17),
            slot="front",
            photo=_jpeg(),
            photo_thumb=_thumb(),
            photo_mime="image/jpeg",
            bytes_=len(_jpeg()),
            sha256=sha,
            now=_now(),
        )
    assert row["slot"] == "front"
    assert row["sha256"] == sha
    assert row["bytes"] == len(_jpeg())

    got = await repo.get_photo(
        user_key=user_key, log_date=DateValue(2026, 5, 17), slot="front", thumb=False
    )
    assert got is not None
    assert got["photo"] == _jpeg()
    assert got["photo_mime"] == "image/jpeg"

    got_thumb = await repo.get_photo(
        user_key=user_key, log_date=DateValue(2026, 5, 17), slot="front", thumb=True
    )
    assert got_thumb is not None
    assert got_thumb["photo"] == _thumb()


@pytest.mark.asyncio
async def test_upsert_replaces_existing_slot(session: AsyncSession) -> None:
    """A second ``upsert`` for the same ``(user_key, log_date, slot)`` replaces the prior row in place."""
    repo = ProgressPhotoRepository(session)
    user_key = f"test-{uuid.uuid4().hex}"
    async with transaction(session):
        await repo.upsert(
            user_key=user_key, log_date=DateValue(2026, 5, 17), slot="front",
            photo=b"v1bytes", photo_thumb=_thumb(), photo_mime="image/jpeg",
            bytes_=7, sha256="sha-v1", now=_now(),
        )
    async with transaction(session):
        row = await repo.upsert(
            user_key=user_key, log_date=DateValue(2026, 5, 17), slot="front",
            photo=b"v2bytes", photo_thumb=_thumb(), photo_mime="image/jpeg",
            bytes_=7, sha256="sha-v2", now=_now(),
        )
    assert row["sha256"] == "sha-v2"
    rows = await repo.list_metadata(
        user_key=user_key, frm=DateValue(2026, 5, 1), to=DateValue(2026, 5, 31)
    )
    assert len(rows) == 1
    assert rows[0]["sha256"] == "sha-v2"


@pytest.mark.asyncio
async def test_list_metadata_filters_by_range(session: AsyncSession) -> None:
    """``list_metadata`` returns only rows whose ``log_date`` falls within the inclusive ``[frm, to]`` window."""
    repo = ProgressPhotoRepository(session)
    user_key = f"test-{uuid.uuid4().hex}"
    async with transaction(session):
        for d, slot in [
            (DateValue(2026, 5, 1), "front"),
            (DateValue(2026, 5, 15), "left"),
            (DateValue(2026, 6, 1), "back"),
        ]:
            await repo.upsert(
                user_key=user_key, log_date=d, slot=slot,
                photo=_jpeg(), photo_thumb=_thumb(), photo_mime="image/jpeg",
                bytes_=len(_jpeg()), sha256=f"sha-{slot}", now=_now(),
            )
    rows = await repo.list_metadata(
        user_key=user_key, frm=DateValue(2026, 5, 1), to=DateValue(2026, 5, 31)
    )
    assert {r["slot"] for r in rows} == {"front", "left"}


@pytest.mark.asyncio
async def test_delete_removes_slot(session: AsyncSession) -> None:
    """``delete`` removes a single slot row so subsequent ``get_photo`` returns ``None``."""
    repo = ProgressPhotoRepository(session)
    user_key = f"test-{uuid.uuid4().hex}"
    async with transaction(session):
        await repo.upsert(
            user_key=user_key, log_date=DateValue(2026, 5, 17), slot="front",
            photo=_jpeg(), photo_thumb=_thumb(), photo_mime="image/jpeg",
            bytes_=len(_jpeg()), sha256="sha", now=_now(),
        )
    async with transaction(session):
        ok = await repo.delete(
            user_key=user_key, log_date=DateValue(2026, 5, 17), slot="front"
        )
    assert ok is True
    assert (
        await repo.get_photo(
            user_key=user_key,
            log_date=DateValue(2026, 5, 17),
            slot="front",
            thumb=False,
        )
        is None
    )
