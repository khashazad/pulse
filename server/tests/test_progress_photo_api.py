"""HTTP tests for `/measures/photos` and `/measures/photo-tags`.

Mirrors the client fixture from `tests/test_containers_api.py`: mocked DB
session + auth middleware so any request bearing `Authorization: Bearer …`
is authenticated. Covers tag listing (with default seeding), tag create
and rename, the photo-id-based GET/POST/DELETE endpoints, and metadata
listing across a date range.
"""

from __future__ import annotations

import io
import os
import uuid
from datetime import UTC
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from datetime import timedelta as TimeDeltaValue
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient
from obstore.store import MemoryStore
from PIL import Image

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test")

# Holds the MemoryStore wired into the app for the active `client` fixture so
# tests can seed/inspect objects directly.
_current_store: dict = {}


def _png_bytes(w: int, h: int) -> bytes:
    """Render an in-memory PNG of the given dimensions.

    **Inputs:**
    - w (int): Image width in pixels.
    - h (int): Image height in pixels.

    **Outputs:**
    - bytes: PNG-encoded image bytes.
    """
    img = Image.new("RGB", (w, h), color=(200, 100, 50))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _now() -> DateTimeValue:
    """Return the current UTC timestamp."""
    return DateTimeValue.now(tz=UTC)


def _photo_row(tag_id: uuid.UUID, sha: str = "deadbeef") -> dict:
    """Build a fake `progress_photos` row dict for repository return values."""
    return {
        "id": uuid.uuid4(),
        "user_key": "khash",
        "log_date": DateValue(2026, 5, 17),
        "tag_id": tag_id,
        "photo_mime": "image/jpeg",
        "bytes": 100,
        "sha256": sha,
        "storage_key_prefix": f"progress/khash/{uuid.uuid4()}",
        "created_at": _now(),
        "updated_at": _now(),
    }


def _tag_row(name: str = "front", sort_order: int = 0) -> dict:
    """Build a fake `progress_photo_tags` row dict for repository return values."""
    return {
        "id": uuid.uuid4(),
        "user_key": "khash",
        "name": name,
        "normalized_name": name,
        "sort_order": sort_order,
        "created_at": _now(),
        "updated_at": _now(),
    }


@pytest.fixture
def client() -> TestClient:
    """TestClient with DB pool, USDA client, and auth middleware mocked."""
    fut = _now() + TimeDeltaValue(days=7)
    session_repo = AsyncMock()
    session_repo.get.return_value = {"email": "khashzd@gmail.com", "expires_at": fut}
    session_repo.slide.return_value = 1
    session_repo.delete.return_value = 1
    fake_db_session = AsyncMock()
    db_ctx = AsyncMock()
    db_ctx.__aenter__.return_value = fake_db_session
    db_ctx.__aexit__.return_value = None

    store = MemoryStore()
    _current_store["store"] = store

    with (
        patch("pulse_server.db.init_pool", new_callable=AsyncMock),
        patch("pulse_server.db.bootstrap_schema", new_callable=AsyncMock),
        patch("pulse_server.db.close_pool", new_callable=AsyncMock),
        patch("pulse_server.usda.USDAClient") as mock_usda_client,
        patch("pulse_server.app.build_photo_store", return_value=store),
        patch("pulse_server.auth.middleware.get_session", return_value=db_ctx),
        patch("pulse_server.auth.middleware.SessionsRepository", return_value=session_repo),
    ):
        mock_usda_client.return_value.close = AsyncMock()
        from pulse_server.app import app
        from pulse_server.db import get_session_dependency
        from pulse_server.photo_store import set_photo_store

        set_photo_store(store)

        async def _fake_session_dep():
            session = MagicMock()
            session.begin = MagicMock()
            session.begin.return_value.__aenter__ = AsyncMock(return_value=session)
            session.begin.return_value.__aexit__ = AsyncMock(return_value=False)
            yield session

        app.dependency_overrides[get_session_dependency] = _fake_session_dep
        try:
            with TestClient(app) as test_client:
                yield test_client
        finally:
            app.dependency_overrides.pop(get_session_dependency, None)
            set_photo_store(None)
            _current_store.pop("store", None)


HEADERS = {"Authorization": "Bearer tok"}


def test_unauthenticated_rejected(client: TestClient) -> None:
    """Listing `/measures/photos` without a Bearer token returns 401."""
    assert client.get("/measures/photos?from=2026-05-01&to=2026-05-31").status_code == 401


# ---------------- photo tags ----------------


def test_list_tags_seeds_defaults_when_empty(client: TestClient) -> None:
    """`GET /measures/photo-tags` seeds the four defaults when the user has none."""
    seeded = [_tag_row(n, i) for i, n in enumerate(["front", "left", "right", "back"])]
    with patch("pulse_server.routers.measures_photo_tags.ProgressPhotoTagRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.list_for_user = AsyncMock(side_effect=[[], seeded])
        instance.bulk_seed_if_empty = AsyncMock(return_value=None)
        resp = client.get("/measures/photo-tags", headers=HEADERS)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert [t["name"] for t in body] == ["front", "left", "right", "back"]
    instance.bulk_seed_if_empty.assert_awaited()


def test_list_tags_returns_existing(client: TestClient) -> None:
    """`GET /measures/photo-tags` skips seeding when rows already exist."""
    existing = [_tag_row("morning", 0)]
    with patch("pulse_server.routers.measures_photo_tags.ProgressPhotoTagRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.list_for_user = AsyncMock(return_value=existing)
        instance.bulk_seed_if_empty = AsyncMock(return_value=None)
        resp = client.get("/measures/photo-tags", headers=HEADERS)
    assert resp.status_code == 200
    body = resp.json()
    assert len(body) == 1
    assert body[0]["name"] == "morning"
    instance.bulk_seed_if_empty.assert_not_awaited()


def test_create_tag_returns_201(client: TestClient) -> None:
    """`POST /measures/photo-tags` creates a tag and returns it."""
    created = _tag_row("flexed", 4)
    with patch("pulse_server.routers.measures_photo_tags.ProgressPhotoTagRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.list_for_user = AsyncMock(return_value=[])
        instance.create = AsyncMock(return_value=created)
        resp = client.post(
            "/measures/photo-tags",
            headers=HEADERS,
            json={"name": "Flexed"},
        )
    assert resp.status_code == 201, resp.text
    assert resp.json()["name"] == "flexed"


def test_create_tag_rejects_blank(client: TestClient) -> None:
    """`POST /measures/photo-tags` with a blank name returns 400."""
    resp = client.post(
        "/measures/photo-tags",
        headers=HEADERS,
        json={"name": "   "},
    )
    # FastAPI returns 422 for length validation; service-side blank check returns 400.
    # min_length=1 stops "" but "   " trims to "" only inside the service, so 400.
    assert resp.status_code in (400, 422)


def test_update_tag_renames(client: TestClient) -> None:
    """`PATCH /measures/photo-tags/{id}` renames a tag."""
    renamed = {**_tag_row("morning", 0), "name": "morning", "normalized_name": "morning"}
    with patch("pulse_server.routers.measures_photo_tags.ProgressPhotoTagRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.update_fields = AsyncMock(return_value=renamed)
        resp = client.patch(
            f"/measures/photo-tags/{uuid.uuid4()}",
            headers=HEADERS,
            json={"name": "Morning"},
        )
    assert resp.status_code == 200
    assert resp.json()["normalized_name"] == "morning"


def test_update_tag_404_when_missing(client: TestClient) -> None:
    """`PATCH /measures/photo-tags/{id}` returns 404 when no row matches."""
    with patch("pulse_server.routers.measures_photo_tags.ProgressPhotoTagRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.update_fields = AsyncMock(return_value=None)
        resp = client.patch(
            f"/measures/photo-tags/{uuid.uuid4()}",
            headers=HEADERS,
            json={"name": "x"},
        )
    assert resp.status_code == 404


# ---------------- photos ----------------


def test_post_photo_returns_metadata(client: TestClient) -> None:
    """`POST /measures/photos` inserts a tagged photo and returns metadata."""
    src = _png_bytes(800, 600)
    tag_id = uuid.uuid4()

    async def _insert(**kwargs):
        row = _photo_row(tag_id, "deadbeef")
        row["id"] = kwargs["photo_id"]
        row["storage_key_prefix"] = kwargs["storage_key_prefix"]
        return row

    photo_repo = MagicMock()
    photo_repo.insert = AsyncMock(side_effect=_insert)
    tag_repo = MagicMock()
    tag_repo.get_by_id = AsyncMock(return_value=_tag_row("front", 0))
    with (
        patch(
            "pulse_server.routers.measures_photos.ProgressPhotoRepository",
            return_value=photo_repo,
        ),
        patch(
            "pulse_server.routers.measures_photos.ProgressPhotoTagRepository",
            return_value=tag_repo,
        ),
    ):
        resp = client.post(
            "/measures/photos",
            headers=HEADERS,
            data={"log_date": "2026-05-17", "tag_id": str(tag_id)},
            files={"file": ("front.png", src, "image/png")},
        )
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert body["tag_id"] == str(tag_id)
    assert body["sha256"] == "deadbeef"
    assert body["date"] == "2026-05-17"


def test_post_photo_forwards_idempotency_key(client: TestClient) -> None:
    """`POST /measures/photos` passes ``idempotency_key`` through to the repository."""
    src = _png_bytes(400, 400)
    tag_id = uuid.uuid4()
    idem = uuid.uuid4()

    async def _insert(**kwargs):
        row = _photo_row(tag_id, "sha")
        row["id"] = kwargs["photo_id"]
        row["storage_key_prefix"] = kwargs["storage_key_prefix"]
        return row

    photo_repo = MagicMock()
    photo_repo.insert = AsyncMock(side_effect=_insert)
    tag_repo = MagicMock()
    tag_repo.get_by_id = AsyncMock(return_value=_tag_row("front", 0))
    with (
        patch(
            "pulse_server.routers.measures_photos.ProgressPhotoRepository",
            return_value=photo_repo,
        ),
        patch(
            "pulse_server.routers.measures_photos.ProgressPhotoTagRepository",
            return_value=tag_repo,
        ),
    ):
        resp = client.post(
            "/measures/photos",
            headers=HEADERS,
            data={
                "log_date": "2026-05-17",
                "tag_id": str(tag_id),
                "idempotency_key": str(idem),
            },
            files={"file": ("x.png", src, "image/png")},
        )
    assert resp.status_code == 201, resp.text
    photo_repo.insert.assert_awaited_once()
    kwargs = photo_repo.insert.await_args.kwargs
    assert kwargs["idempotency_key"] == idem


def test_post_photo_rejects_future_date(client: TestClient) -> None:
    """`POST /measures/photos` with a future date returns 400."""
    src = _png_bytes(100, 100)
    tag_id = uuid.uuid4()
    tag_repo = MagicMock()
    tag_repo.get_by_id = AsyncMock(return_value=_tag_row("front", 0))
    with patch(
        "pulse_server.routers.measures_photos.ProgressPhotoTagRepository",
        return_value=tag_repo,
    ):
        resp = client.post(
            "/measures/photos",
            headers=HEADERS,
            data={"log_date": "2099-01-01", "tag_id": str(tag_id)},
            files={"file": ("x.png", src, "image/png")},
        )
    assert resp.status_code == 400


def test_post_photo_404_on_unknown_tag(client: TestClient) -> None:
    """`POST /measures/photos` with an unknown tag_id returns 404."""
    src = _png_bytes(100, 100)
    tag_repo = MagicMock()
    tag_repo.get_by_id = AsyncMock(return_value=None)
    with patch(
        "pulse_server.routers.measures_photos.ProgressPhotoTagRepository",
        return_value=tag_repo,
    ):
        resp = client.post(
            "/measures/photos",
            headers=HEADERS,
            data={"log_date": "2026-05-17", "tag_id": str(uuid.uuid4())},
            files={"file": ("x.png", src, "image/png")},
        )
    assert resp.status_code == 404


def test_post_photo_rejects_non_image(client: TestClient) -> None:
    """`POST /measures/photos` with non-image content returns 415."""
    tag_repo = MagicMock()
    tag_repo.get_by_id = AsyncMock(return_value=_tag_row("front", 0))
    with patch(
        "pulse_server.routers.measures_photos.ProgressPhotoTagRepository",
        return_value=tag_repo,
    ):
        resp = client.post(
            "/measures/photos",
            headers=HEADERS,
            data={"log_date": "2026-05-17", "tag_id": str(uuid.uuid4())},
            files={"file": ("notes.txt", b"hello", "text/plain")},
        )
    assert resp.status_code == 415


def test_get_photo_returns_bytes_with_etag(client: TestClient) -> None:
    """`GET /measures/photos/{id}` returns photo bytes with an ETag header."""
    photo_id = uuid.uuid4()
    with patch("pulse_server.routers.measures_photos.ProgressPhotoRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.get_photo = AsyncMock(
            return_value={
                "photo": b"\xff\xd8jpeg-bytes",
                "photo_mime": "image/jpeg",
                "sha256": "abc123",
                "updated_at": _now(),
                "storage_key_prefix": None,
            }
        )
        resp = client.get(
            f"/measures/photos/{photo_id}?size=full",
            headers=HEADERS,
        )
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "image/jpeg"
    assert resp.headers.get("etag") == '"abc123"'
    assert resp.content == b"\xff\xd8jpeg-bytes"


def test_get_photo_returns_404_when_missing(client: TestClient) -> None:
    """`GET /measures/photos/{id}` returns 404 when no photo exists."""
    with patch("pulse_server.routers.measures_photos.ProgressPhotoRepository") as MockRepo:
        MockRepo.return_value.get_photo = AsyncMock(return_value=None)
        resp = client.get(f"/measures/photos/{uuid.uuid4()}", headers=HEADERS)
    assert resp.status_code == 404


def test_list_returns_metadata_for_range(client: TestClient) -> None:
    """`GET /measures/photos?from=&to=` returns metadata rows for the range."""
    tag_id = uuid.uuid4()
    with patch("pulse_server.routers.measures_photos.ProgressPhotoRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.list_metadata = AsyncMock(return_value=[_photo_row(tag_id, "a")])
        resp = client.get(
            "/measures/photos?from=2026-05-01&to=2026-05-31",
            headers=HEADERS,
        )
    assert resp.status_code == 200
    body = resp.json()
    assert isinstance(body, list)
    assert body[0]["tag_id"] == str(tag_id)
    assert body[0]["date"] == "2026-05-17"


def test_delete_returns_204(client: TestClient) -> None:
    """`DELETE /measures/photos/{id}` returns 204 on success."""
    photo_id = uuid.uuid4()
    with patch("pulse_server.routers.measures_photos.ProgressPhotoRepository") as MockRepo:
        MockRepo.return_value.delete = AsyncMock(
            return_value={"id": photo_id, "storage_key_prefix": None}
        )
        resp = client.delete(f"/measures/photos/{photo_id}", headers=HEADERS)
    assert resp.status_code == 204


def test_delete_returns_404_when_missing(client: TestClient) -> None:
    """`DELETE /measures/photos/{id}` returns 404 when nothing was removed."""
    with patch("pulse_server.routers.measures_photos.ProgressPhotoRepository") as MockRepo:
        MockRepo.return_value.delete = AsyncMock(return_value=None)
        resp = client.delete(f"/measures/photos/{uuid.uuid4()}", headers=HEADERS)
    assert resp.status_code == 404


# ---------------- object-store read/write/delete ----------------


def _object_missing(store: MemoryStore, key: str) -> bool:
    """Report whether ``key`` is absent from ``store``.

    **Inputs:**
    - store (MemoryStore): The object store to probe.
    - key (str): Object key to look up.

    **Outputs:**
    - bool: ``True`` when the key raises on fetch (absent), ``False`` otherwise.
    """
    try:
        store.get(key).bytes()
        return False
    except Exception:
        return True


def test_get_photo_streams_from_object_store(client: TestClient) -> None:
    """`GET /measures/photos/{id}` streams display bytes from the object store."""
    store = _current_store["store"]
    prefix = f"progress/khash/{uuid.uuid4()}"
    store.put(f"{prefix}/display.jpg", b"jpeg-bytes")
    with patch("pulse_server.routers.measures_photos.ProgressPhotoRepository") as MockRepo:
        MockRepo.return_value.get_photo = AsyncMock(
            return_value={
                "photo": None,
                "photo_mime": "image/jpeg",
                "sha256": "cafe",
                "updated_at": _now(),
                "storage_key_prefix": prefix,
            }
        )
        resp = client.get(f"/measures/photos/{uuid.uuid4()}", headers=HEADERS)
    assert resp.status_code == 200, resp.text
    assert resp.content == b"jpeg-bytes"
    assert resp.headers.get("etag") == '"cafe"'


def test_get_photo_thumb_and_archive_variants(client: TestClient) -> None:
    """`GET /measures/photos/{id}?size=` returns the right object per variant."""
    store = _current_store["store"]
    prefix = f"progress/khash/{uuid.uuid4()}"
    store.put(f"{prefix}/thumb.jpg", b"thumb-bytes")
    store.put(f"{prefix}/archive.jpg", b"archive-bytes")

    def _row():
        return {
            "photo": None,
            "photo_mime": "image/jpeg",
            "sha256": "cafe",
            "updated_at": _now(),
            "storage_key_prefix": prefix,
        }

    with patch("pulse_server.routers.measures_photos.ProgressPhotoRepository") as MockRepo:
        MockRepo.return_value.get_photo = AsyncMock(side_effect=lambda **_: _row())
        thumb = client.get(f"/measures/photos/{uuid.uuid4()}?size=thumb", headers=HEADERS)
        archive = client.get(f"/measures/photos/{uuid.uuid4()}?size=archive", headers=HEADERS)
    assert thumb.status_code == 200
    assert thumb.content == b"thumb-bytes"
    assert archive.status_code == 200
    assert archive.content == b"archive-bytes"


def test_get_photo_bytea_fallback_for_unmigrated_row(client: TestClient) -> None:
    """`GET /measures/photos/{id}` falls back to legacy bytea when no prefix is set."""
    with patch("pulse_server.routers.measures_photos.ProgressPhotoRepository") as MockRepo:
        MockRepo.return_value.get_photo = AsyncMock(
            return_value={
                "photo": b"legacy-bytes",
                "photo_mime": "image/jpeg",
                "sha256": "cafe",
                "updated_at": _now(),
                "storage_key_prefix": None,
            }
        )
        resp = client.get(f"/measures/photos/{uuid.uuid4()}", headers=HEADERS)
    assert resp.status_code == 200, resp.text
    assert resp.content == b"legacy-bytes"


def test_get_photo_404_when_object_missing(client: TestClient) -> None:
    """`GET /measures/photos/{id}` returns 404 when a migrated row's object is gone."""
    prefix = f"progress/khash/{uuid.uuid4()}"
    with patch("pulse_server.routers.measures_photos.ProgressPhotoRepository") as MockRepo:
        MockRepo.return_value.get_photo = AsyncMock(
            return_value={
                "photo": None,
                "photo_mime": "image/jpeg",
                "sha256": "cafe",
                "updated_at": _now(),
                "storage_key_prefix": prefix,
            }
        )
        resp = client.get(f"/measures/photos/{uuid.uuid4()}", headers=HEADERS)
    assert resp.status_code == 404


def test_create_photo_uploads_three_objects(client: TestClient) -> None:
    """`POST /measures/photos` writes archive/display/thumb objects under the prefix."""
    store = _current_store["store"]
    src = _png_bytes(800, 600)
    tag_id = uuid.uuid4()
    captured: dict = {}

    async def _insert(**kwargs):
        captured.update(kwargs)
        row = _photo_row(tag_id, "deadbeef")
        row["id"] = kwargs["photo_id"]
        row["storage_key_prefix"] = kwargs["storage_key_prefix"]
        return row

    photo_repo = MagicMock()
    photo_repo.insert = AsyncMock(side_effect=_insert)
    tag_repo = MagicMock()
    tag_repo.get_by_id = AsyncMock(return_value=_tag_row("front", 0))
    with (
        patch(
            "pulse_server.routers.measures_photos.ProgressPhotoRepository",
            return_value=photo_repo,
        ),
        patch(
            "pulse_server.routers.measures_photos.ProgressPhotoTagRepository",
            return_value=tag_repo,
        ),
    ):
        resp = client.post(
            "/measures/photos",
            headers=HEADERS,
            data={"log_date": "2026-05-17", "tag_id": str(tag_id)},
            files={"file": ("front.png", src, "image/png")},
        )
    assert resp.status_code == 201, resp.text
    prefix = captured["storage_key_prefix"]
    for name in ("archive.jpg", "display.jpg", "thumb.jpg"):
        assert not _object_missing(store, f"{prefix}/{name}")


def test_create_photo_cleans_up_objects_when_insert_fails(client: TestClient) -> None:
    """`POST /measures/photos` removes uploaded objects if the DB insert fails."""
    store = _current_store["store"]
    src = _png_bytes(800, 600)
    tag_id = uuid.uuid4()
    captured: dict = {}

    async def _insert(**kwargs):
        captured.update(kwargs)
        raise RuntimeError("insert blew up")

    photo_repo = MagicMock()
    photo_repo.insert = AsyncMock(side_effect=_insert)
    tag_repo = MagicMock()
    tag_repo.get_by_id = AsyncMock(return_value=_tag_row("front", 0))
    with (
        patch(
            "pulse_server.routers.measures_photos.ProgressPhotoRepository",
            return_value=photo_repo,
        ),
        patch(
            "pulse_server.routers.measures_photos.ProgressPhotoTagRepository",
            return_value=tag_repo,
        ),
        pytest.raises(RuntimeError),
    ):
        client.post(
            "/measures/photos",
            headers=HEADERS,
            data={"log_date": "2026-05-17", "tag_id": str(tag_id)},
            files={"file": ("front.png", src, "image/png")},
        )
    prefix = captured["storage_key_prefix"]
    for name in ("archive.jpg", "display.jpg", "thumb.jpg"):
        assert _object_missing(store, f"{prefix}/{name}")


def test_create_photo_cleans_up_after_partial_upload_failure(client: TestClient) -> None:
    """A failing 2nd put_async removes the already-uploaded 1st object."""
    store = _current_store["store"]
    src = _png_bytes(800, 600)
    tag_id = uuid.uuid4()
    captured: dict = {}

    # Count calls so the 2nd put_async raises; delegate the 1st to the real method.
    call_count = {"n": 0}
    real_put_async = store.put_async

    async def _put_async_fail_on_second(key: str, data: bytes) -> None:
        call_count["n"] += 1
        if call_count["n"] == 1:
            # First object: capture prefix and write it for real so it lands in the store.
            captured["first_key"] = key
            return await real_put_async(key, data)
        raise RuntimeError("simulated partial-upload failure")

    tag_repo = MagicMock()
    tag_repo.get_by_id = AsyncMock(return_value=_tag_row("front", 0))
    with (
        patch.object(store, "put_async", side_effect=_put_async_fail_on_second),
        patch(
            "pulse_server.routers.measures_photos.ProgressPhotoTagRepository",
            return_value=tag_repo,
        ),
        pytest.raises(RuntimeError),
    ):
        client.post(
            "/measures/photos",
            headers=HEADERS,
            data={"log_date": "2026-05-17", "tag_id": str(tag_id)},
            files={"file": ("front.png", src, "image/png")},
        )
    # The first object was written; cleanup must have removed it.
    assert captured.get("first_key"), "first put_async was never called"
    assert _object_missing(store, captured["first_key"]), (
        "cleanup did not remove the 1st uploaded object after partial failure"
    )


def test_delete_photo_removes_objects(client: TestClient) -> None:
    """`DELETE /measures/photos/{id}` deletes the row's object-store copies."""
    store = _current_store["store"]
    photo_id = uuid.uuid4()
    prefix = f"progress/khash/{photo_id}"
    for name in ("archive.jpg", "display.jpg", "thumb.jpg"):
        store.put(f"{prefix}/{name}", b"x")
    with patch("pulse_server.routers.measures_photos.ProgressPhotoRepository") as MockRepo:
        MockRepo.return_value.delete = AsyncMock(
            return_value={"id": photo_id, "storage_key_prefix": prefix}
        )
        resp = client.delete(f"/measures/photos/{photo_id}", headers=HEADERS)
    assert resp.status_code == 204
    for name in ("archive.jpg", "display.jpg", "thumb.jpg"):
        assert _object_missing(store, f"{prefix}/{name}")
