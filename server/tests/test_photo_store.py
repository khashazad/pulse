"""Tests for the photo object-store factory, provider, and read primitive."""

from __future__ import annotations

import asyncio
import os
from pathlib import Path

import pytest
from obstore.store import LocalStore, MemoryStore, S3Store

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test")

from pulse_server.config import Settings
from pulse_server.photo_store import (
    build_photo_store,
    get_photo_object,
    get_photo_store,
    set_photo_store,
)


def test_build_returns_s3_store_when_configured() -> None:
    """Fully configured S3 settings produce an S3Store."""
    settings = Settings(
        database_url="postgresql://x/y",
        usda_api_key="k",
        s3_endpoint="https://acc.r2.cloudflarestorage.com",
        s3_bucket="pulse-photos",
        s3_access_key_id="ak",
        s3_secret_access_key="sk",
    )
    assert isinstance(build_photo_store(settings), S3Store)


def test_build_falls_back_to_local_store(tmp_path: Path) -> None:
    """Without S3 config the factory creates a LocalStore under photo_store_dir."""
    settings = Settings(
        database_url="postgresql://x/y",
        usda_api_key="k",
        photo_store_dir=str(tmp_path / "photos"),
    )
    store = build_photo_store(settings)
    assert isinstance(store, LocalStore)
    assert (tmp_path / "photos").is_dir()


def test_provider_round_trip_and_unset_raises() -> None:
    """`get_photo_store` returns the published store and raises when unset."""
    set_photo_store(None)
    with pytest.raises(RuntimeError):
        get_photo_store()
    store = MemoryStore()
    set_photo_store(store)
    try:
        assert get_photo_store() is store
    finally:
        set_photo_store(None)


def test_get_photo_object_returns_bytes_or_none(tmp_path: Path) -> None:
    """`get_photo_object` returns the object's bytes, or ``None`` when absent.

    Runs against both the Memory and Local backends because they raise
    different missing-key exceptions (stdlib ``FileNotFoundError``) than the
    S3 backend (obstore ``NotFoundError``); the helper must normalize both.
    """

    async def _roundtrip(store: MemoryStore | LocalStore) -> None:
        await store.put_async("p/display.jpg", b"jpeg")
        hit = await get_photo_object(store, "p/display.jpg")
        assert hit is not None
        assert bytes(hit) == b"jpeg"
        assert await get_photo_object(store, "p/missing.jpg") is None

    asyncio.run(_roundtrip(MemoryStore()))
    asyncio.run(_roundtrip(LocalStore(tmp_path)))
