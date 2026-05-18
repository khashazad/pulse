"""Integration tests for ``ProgressPhotoRepository`` and ``ProgressPhotoTagRepository``.

Covers the per-user tag catalog (seed + list + create + rename) and the
photo-id-based progress-photo persistence (insert one or many per
``(user_key, log_date, tag_id)``, range filtering, full vs. thumb retrieval,
and deletion). Integration test: hits a real Postgres via
``TEST_DATABASE_URL``.
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
from diet_tracker_server.repositories.progress_photo_tag import (
    ProgressPhotoTagRepository,
)

pytestmark = pytest.mark.integration


def _integration_database_url() -> str:
    """Resolve the SQLAlchemy URL for the integration database, skipping if unset."""
    raw_url = os.getenv("TEST_DATABASE_URL")
    if raw_url is None:
        pytest.skip("Set TEST_DATABASE_URL to run integration tests")
    return to_sqlalchemy_url(raw_url)


async def _truncate(engine) -> None:
    """Truncate progress-photo tables, restarting identity sequences."""
    async with engine.begin() as conn:
        await conn.exec_driver_sql(
            "TRUNCATE TABLE progress_photos, progress_photo_tags RESTART IDENTITY CASCADE"
        )


@pytest_asyncio.fixture
async def session() -> AsyncSession:
    """Per-test async session with freshly-truncated progress-photo tables."""
    engine = create_async_engine(_integration_database_url())
    await _truncate(engine)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as s:
        yield s
    await engine.dispose()


def _now() -> DateTimeValue:
    """Return the current UTC timestamp."""
    return DateTimeValue.now(tz=TimezoneValue.utc)


def _jpeg() -> bytes:
    """Return a fixed byte payload representing a full-size JPEG body."""
    return b"\xff\xd8\xff\xe0fake-jpeg-bytes"


def _thumb() -> bytes:
    """Return a fixed byte payload representing a thumbnail JPEG body."""
    return b"\xff\xd8\xff\xe0fake-thumb"


async def _seed_tag(session: AsyncSession, *, user_key: str, name: str = "front", order: int = 0):
    """Insert a single tag row and return its id, transactionally."""
    repo = ProgressPhotoTagRepository(session)
    async with transaction(session):
        row = await repo.create(
            user_key=user_key,
            name=name,
            normalized_name=name,
            sort_order=order,
            now=_now(),
        )
    return row["id"]


@pytest.mark.asyncio
async def test_insert_then_get_round_trip(session: AsyncSession) -> None:
    """``insert`` persists photo bytes and ``get_photo`` returns full + thumbnail bytes by id."""
    user_key = f"test-{uuid.uuid4().hex}"
    tag_id = await _seed_tag(session, user_key=user_key, name="front")
    repo = ProgressPhotoRepository(session)
    sha = hashlib.sha256(_jpeg()).hexdigest()
    async with transaction(session):
        row = await repo.insert(
            user_key=user_key,
            log_date=DateValue(2026, 5, 17),
            tag_id=tag_id,
            photo=_jpeg(),
            photo_thumb=_thumb(),
            photo_mime="image/jpeg",
            bytes_=len(_jpeg()),
            sha256=sha,
            now=_now(),
        )
    photo_id = row["id"]
    assert row["tag_id"] == tag_id
    assert row["sha256"] == sha
    assert row["bytes"] == len(_jpeg())

    got = await repo.get_photo(photo_id=photo_id, user_key=user_key, thumb=False)
    assert got is not None
    assert got["photo"] == _jpeg()
    assert got["photo_mime"] == "image/jpeg"

    got_thumb = await repo.get_photo(photo_id=photo_id, user_key=user_key, thumb=True)
    assert got_thumb is not None
    assert got_thumb["photo"] == _thumb()


@pytest.mark.asyncio
async def test_idempotency_key_dedupes_repeat_insert(session: AsyncSession) -> None:
    """A second insert with the same ``(user_key, idempotency_key)`` returns the existing row.

    Guards against duplicate progress photos when the iOS upload queue
    retries a POST after a partial local failure (e.g. cache rename / queue
    persistence error after the network request already succeeded).
    """
    user_key = f"test-{uuid.uuid4().hex}"
    tag_id = await _seed_tag(session, user_key=user_key)
    repo = ProgressPhotoRepository(session)
    idem = uuid.uuid4()
    async with transaction(session):
        first = await repo.insert(
            user_key=user_key, log_date=DateValue(2026, 5, 17), tag_id=tag_id,
            photo=b"v1bytes", photo_thumb=_thumb(), photo_mime="image/jpeg",
            bytes_=7, sha256="sha-v1", now=_now(), idempotency_key=idem,
        )
    async with transaction(session):
        second = await repo.insert(
            user_key=user_key, log_date=DateValue(2026, 5, 17), tag_id=tag_id,
            photo=b"v2bytes", photo_thumb=_thumb(), photo_mime="image/jpeg",
            bytes_=7, sha256="sha-v2", now=_now(), idempotency_key=idem,
        )
    assert second["id"] == first["id"]
    assert second["sha256"] == "sha-v1"  # pre-existing row returned, not overwritten
    rows = await repo.list_metadata(
        user_key=user_key, frm=DateValue(2026, 5, 1), to=DateValue(2026, 5, 31)
    )
    assert len(rows) == 1


@pytest.mark.asyncio
async def test_null_idempotency_keys_dont_collide(session: AsyncSession) -> None:
    """Inserts without ``idempotency_key`` always create a new row (NULLs distinct)."""
    user_key = f"test-{uuid.uuid4().hex}"
    tag_id = await _seed_tag(session, user_key=user_key)
    repo = ProgressPhotoRepository(session)
    async with transaction(session):
        await repo.insert(
            user_key=user_key, log_date=DateValue(2026, 5, 17), tag_id=tag_id,
            photo=b"a", photo_thumb=_thumb(), photo_mime="image/jpeg",
            bytes_=1, sha256="sha-a", now=_now(),
        )
    async with transaction(session):
        await repo.insert(
            user_key=user_key, log_date=DateValue(2026, 5, 17), tag_id=tag_id,
            photo=b"b", photo_thumb=_thumb(), photo_mime="image/jpeg",
            bytes_=1, sha256="sha-b", now=_now(),
        )
    rows = await repo.list_metadata(
        user_key=user_key, frm=DateValue(2026, 5, 1), to=DateValue(2026, 5, 31)
    )
    assert len(rows) == 2


@pytest.mark.asyncio
async def test_multiple_photos_per_date_and_tag(session: AsyncSession) -> None:
    """Two ``insert`` calls for the same ``(user_key, log_date, tag_id)`` both persist."""
    user_key = f"test-{uuid.uuid4().hex}"
    tag_id = await _seed_tag(session, user_key=user_key)
    repo = ProgressPhotoRepository(session)
    async with transaction(session):
        await repo.insert(
            user_key=user_key, log_date=DateValue(2026, 5, 17), tag_id=tag_id,
            photo=b"v1bytes", photo_thumb=_thumb(), photo_mime="image/jpeg",
            bytes_=7, sha256="sha-v1", now=_now(),
        )
    async with transaction(session):
        await repo.insert(
            user_key=user_key, log_date=DateValue(2026, 5, 17), tag_id=tag_id,
            photo=b"v2bytes", photo_thumb=_thumb(), photo_mime="image/jpeg",
            bytes_=7, sha256="sha-v2", now=_now(),
        )
    rows = await repo.list_metadata(
        user_key=user_key, frm=DateValue(2026, 5, 1), to=DateValue(2026, 5, 31)
    )
    assert len(rows) == 2
    assert {r["sha256"] for r in rows} == {"sha-v1", "sha-v2"}


@pytest.mark.asyncio
async def test_list_metadata_filters_by_range(session: AsyncSession) -> None:
    """``list_metadata`` returns only rows whose ``log_date`` falls within ``[frm, to]``."""
    user_key = f"test-{uuid.uuid4().hex}"
    tag_id = await _seed_tag(session, user_key=user_key)
    repo = ProgressPhotoRepository(session)
    async with transaction(session):
        for d in [DateValue(2026, 5, 1), DateValue(2026, 5, 15), DateValue(2026, 6, 1)]:
            await repo.insert(
                user_key=user_key, log_date=d, tag_id=tag_id,
                photo=_jpeg(), photo_thumb=_thumb(), photo_mime="image/jpeg",
                bytes_=len(_jpeg()), sha256=f"sha-{d.isoformat()}", now=_now(),
            )
    rows = await repo.list_metadata(
        user_key=user_key, frm=DateValue(2026, 5, 1), to=DateValue(2026, 5, 31)
    )
    assert {r["log_date"] for r in rows} == {DateValue(2026, 5, 1), DateValue(2026, 5, 15)}


@pytest.mark.asyncio
async def test_delete_removes_photo(session: AsyncSession) -> None:
    """``delete`` removes a single photo by id so ``get_photo`` returns ``None``."""
    user_key = f"test-{uuid.uuid4().hex}"
    tag_id = await _seed_tag(session, user_key=user_key)
    repo = ProgressPhotoRepository(session)
    async with transaction(session):
        row = await repo.insert(
            user_key=user_key, log_date=DateValue(2026, 5, 17), tag_id=tag_id,
            photo=_jpeg(), photo_thumb=_thumb(), photo_mime="image/jpeg",
            bytes_=len(_jpeg()), sha256="sha", now=_now(),
        )
    photo_id = row["id"]
    async with transaction(session):
        ok = await repo.delete(photo_id=photo_id, user_key=user_key)
    assert ok is True
    assert (
        await repo.get_photo(photo_id=photo_id, user_key=user_key, thumb=False)
        is None
    )


@pytest.mark.asyncio
async def test_tag_create_list_rename(session: AsyncSession) -> None:
    """`ProgressPhotoTagRepository` supports create, list, and rename via update_fields."""
    user_key = f"test-{uuid.uuid4().hex}"
    repo = ProgressPhotoTagRepository(session)
    async with transaction(session):
        await repo.create(
            user_key=user_key, name="Morning", normalized_name="morning",
            sort_order=0, now=_now(),
        )
        await repo.create(
            user_key=user_key, name="Evening", normalized_name="evening",
            sort_order=1, now=_now(),
        )
    rows = await repo.list_for_user(user_key)
    assert [r["normalized_name"] for r in rows] == ["morning", "evening"]

    morning_id = rows[0]["id"]
    async with transaction(session):
        updated = await repo.update_fields(
            tag_id=morning_id, user_key=user_key,
            fields={"name": "AM", "normalized_name": "am"}, now=_now(),
        )
    assert updated is not None
    assert updated["normalized_name"] == "am"


@pytest.mark.asyncio
async def test_bulk_seed_if_empty_is_idempotent(session: AsyncSession) -> None:
    """Re-running ``bulk_seed_if_empty`` does not duplicate rows."""
    user_key = f"test-{uuid.uuid4().hex}"
    repo = ProgressPhotoTagRepository(session)
    defaults = [("front", "front", 0), ("back", "back", 1)]
    async with transaction(session):
        await repo.bulk_seed_if_empty(user_key=user_key, defaults=defaults, now=_now())
    async with transaction(session):
        await repo.bulk_seed_if_empty(user_key=user_key, defaults=defaults, now=_now())
    rows = await repo.list_for_user(user_key)
    assert len(rows) == 2
