"""Unit tests for the one-off bytea → object-store migration helper.

Loads the script via ``importlib`` (mirroring ``test_import_hevy_weights.py``)
and exercises :func:`copy_row_objects` against an in-memory store; the DB
loop in ``main`` is covered by the prod run's per-row read-back verification.
"""

from __future__ import annotations

import importlib.util
import os
import uuid
from pathlib import Path

from obstore.store import MemoryStore

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test")


def _load_script():
    """Import the migration script as a module from its file path.

    **Outputs:**
    - module: The loaded ``migrate_photos_to_object_store`` module.

    **Exceptions:**
    - AssertionError: Raised when the import spec cannot be created.
    """
    path = Path("scripts/migrate_photos_to_object_store.py")
    spec = importlib.util.spec_from_file_location("migrate_photos_to_object_store", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


async def test_copy_row_objects_writes_three_objects() -> None:
    """The 1600px blob lands as both display and archive; thumb as thumb."""
    module = _load_script()
    store = MemoryStore()
    row = {
        "id": uuid.uuid4(),
        "user_key": "khash",
        "photo": b"full-bytes",
        "photo_thumb": b"thumb-bytes",
    }
    prefix = await module.copy_row_objects(store, row)
    assert prefix == f"progress/khash/{row['id']}"

    async def _get(key: str) -> bytes:
        return bytes(await (await store.get_async(key)).bytes_async())

    assert await _get(f"{prefix}/display.jpg") == b"full-bytes"
    assert await _get(f"{prefix}/archive.jpg") == b"full-bytes"
    assert await _get(f"{prefix}/thumb.jpg") == b"thumb-bytes"
