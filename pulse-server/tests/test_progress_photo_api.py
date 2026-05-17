"""HTTP tests for /measures/photos.

Mirrors the client fixture from tests/test_containers_api.py: mocked DB
session + middleware so any request with `Authorization: Bearer …` is authed.
"""

from __future__ import annotations

import io
import os
import uuid
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from datetime import timedelta as TimeDeltaValue
from datetime import timezone as TimezoneValue
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient
from PIL import Image

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test")


def _png_bytes(w: int, h: int) -> bytes:
    img = Image.new("RGB", (w, h), color=(200, 100, 50))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _now() -> DateTimeValue:
    return DateTimeValue.now(tz=TimezoneValue.utc)


def _row(slot: str = "front", sha: str = "deadbeef") -> dict:
    return {
        "id": uuid.uuid4(),
        "user_key": "khash",
        "log_date": DateValue(2026, 5, 17),
        "slot": slot,
        "photo_mime": "image/jpeg",
        "bytes": 100,
        "sha256": sha,
        "created_at": _now(),
        "updated_at": _now(),
    }


@pytest.fixture
def client() -> TestClient:
    fut = _now() + TimeDeltaValue(days=7)
    session_repo = AsyncMock()
    session_repo.get.return_value = {"email": "khashzd@gmail.com", "expires_at": fut}
    session_repo.slide.return_value = 1
    session_repo.delete.return_value = 1
    fake_db_session = AsyncMock()
    db_ctx = AsyncMock()
    db_ctx.__aenter__.return_value = fake_db_session
    db_ctx.__aexit__.return_value = None

    with patch("diet_tracker_server.db.init_pool", new_callable=AsyncMock), patch(
        "diet_tracker_server.db.bootstrap_schema", new_callable=AsyncMock
    ), patch("diet_tracker_server.db.close_pool", new_callable=AsyncMock), patch(
        "diet_tracker_server.usda.USDAClient"
    ) as mock_usda_client, patch(
        "diet_tracker_server.auth.middleware.get_session", return_value=db_ctx
    ), patch(
        "diet_tracker_server.auth.middleware.SessionsRepository", return_value=session_repo
    ):
        mock_usda_client.return_value.close = AsyncMock()
        from diet_tracker_server.app import app
        from diet_tracker_server.db import get_session_dependency

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


HEADERS = {"Authorization": "Bearer tok"}


def test_unauthenticated_rejected(client: TestClient) -> None:
    assert client.get("/measures/photos?from=2026-05-01&to=2026-05-31").status_code == 401


def test_put_single_photo_returns_metadata(client: TestClient) -> None:
    src = _png_bytes(800, 600)
    with patch(
        "diet_tracker_server.routers.measures_photos.ProgressPhotoRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.upsert = AsyncMock(return_value=_row(slot="front", sha="deadbeef"))
        resp = client.put(
            "/measures/photos/2026-05-17/front",
            headers=HEADERS,
            files={"file": ("front.png", src, "image/png")},
        )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["slot"] == "front"
    assert body["sha256"] == "deadbeef"
    assert body["date"] == "2026-05-17"


def test_put_single_photo_rejects_future_date(client: TestClient) -> None:
    src = _png_bytes(100, 100)
    resp = client.put(
        "/measures/photos/2099-01-01/front",
        headers=HEADERS,
        files={"file": ("front.png", src, "image/png")},
    )
    assert resp.status_code == 400


def test_put_single_photo_rejects_bad_slot(client: TestClient) -> None:
    src = _png_bytes(100, 100)
    resp = client.put(
        "/measures/photos/2026-05-17/topdown",
        headers=HEADERS,
        files={"file": ("x.png", src, "image/png")},
    )
    assert resp.status_code == 400


def test_put_single_photo_rejects_non_image(client: TestClient) -> None:
    resp = client.put(
        "/measures/photos/2026-05-17/front",
        headers=HEADERS,
        files={"file": ("notes.txt", b"hello", "text/plain")},
    )
    assert resp.status_code == 415


def test_get_photo_returns_bytes_with_etag(client: TestClient) -> None:
    with patch(
        "diet_tracker_server.routers.measures_photos.ProgressPhotoRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.get_photo = AsyncMock(
            return_value={
                "photo": b"\xff\xd8jpeg-bytes",
                "photo_mime": "image/jpeg",
                "sha256": "abc123",
                "updated_at": _now(),
            }
        )
        resp = client.get(
            "/measures/photos/2026-05-17/front?size=full",
            headers=HEADERS,
        )
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "image/jpeg"
    assert resp.headers.get("etag") == '"abc123"'
    assert resp.content == b"\xff\xd8jpeg-bytes"


def test_get_photo_returns_404_when_missing(client: TestClient) -> None:
    with patch(
        "diet_tracker_server.routers.measures_photos.ProgressPhotoRepository"
    ) as MockRepo:
        MockRepo.return_value.get_photo = AsyncMock(return_value=None)
        resp = client.get("/measures/photos/2026-05-17/front", headers=HEADERS)
    assert resp.status_code == 404


def test_list_returns_metadata_for_range(client: TestClient) -> None:
    with patch(
        "diet_tracker_server.routers.measures_photos.ProgressPhotoRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.list_metadata = AsyncMock(return_value=[_row("front", "a")])
        resp = client.get(
            "/measures/photos?from=2026-05-01&to=2026-05-31",
            headers=HEADERS,
        )
    assert resp.status_code == 200
    body = resp.json()
    assert isinstance(body, list)
    assert body[0]["slot"] == "front"
    assert body[0]["date"] == "2026-05-17"


def test_delete_returns_204(client: TestClient) -> None:
    with patch(
        "diet_tracker_server.routers.measures_photos.ProgressPhotoRepository"
    ) as MockRepo:
        MockRepo.return_value.delete = AsyncMock(return_value=True)
        resp = client.delete("/measures/photos/2026-05-17/front", headers=HEADERS)
    assert resp.status_code == 204


def test_delete_returns_404_when_missing(client: TestClient) -> None:
    with patch(
        "diet_tracker_server.routers.measures_photos.ProgressPhotoRepository"
    ) as MockRepo:
        MockRepo.return_value.delete = AsyncMock(return_value=False)
        resp = client.delete("/measures/photos/2026-05-17/front", headers=HEADERS)
    assert resp.status_code == 404


def test_put_batch_uploads_multiple_slots(client: TestClient) -> None:
    src1 = _png_bytes(400, 600)
    src2 = _png_bytes(400, 600)
    with patch(
        "diet_tracker_server.routers.measures_photos.ProgressPhotoRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.upsert = AsyncMock(
            side_effect=[
                _row(slot="front", sha="sha-front"),
                _row(slot="back", sha="sha-back"),
            ]
        )
        resp = client.put(
            "/measures/photos/2026-05-17",
            headers=HEADERS,
            files=[
                ("front", ("f.png", src1, "image/png")),
                ("back", ("b.png", src2, "image/png")),
            ],
        )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert len(body) == 2
    assert {row["slot"] for row in body} == {"front", "back"}


def test_put_batch_rejects_empty_request(client: TestClient) -> None:
    resp = client.put("/measures/photos/2026-05-17", headers=HEADERS, files=[])
    assert resp.status_code == 400


def test_put_batch_rejects_unknown_slot_field(client: TestClient) -> None:
    src = _png_bytes(100, 100)
    resp = client.put(
        "/measures/photos/2026-05-17",
        headers=HEADERS,
        files=[("topdown", ("t.png", src, "image/png"))],
    )
    assert resp.status_code == 400


def test_put_batch_rejects_future_date(client: TestClient) -> None:
    src = _png_bytes(100, 100)
    resp = client.put(
        "/measures/photos/2099-01-01",
        headers=HEADERS,
        files=[("front", ("f.png", src, "image/png"))],
    )
    assert resp.status_code == 400
