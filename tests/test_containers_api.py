"""HTTP tests for `/containers` and `/containers/{id}/photo`.

Covers listing, create (success, validation error, duplicate-name 409),
get/404, patch, delete, and the photo upload/get/delete endpoints
including the streaming size cap (413), non-image rejection (415), and
JPEG retrieval. Uses a TestClient with DB and auth middleware mocked.
"""

from __future__ import annotations

import io
import os
import uuid
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
    """Render an in-memory PNG of the given dimensions.

    **Inputs:**
    - w (int): Image width in pixels.
    - h (int): Image height in pixels.

    **Outputs:**
    - bytes: PNG-encoded image bytes.
    """
    img = Image.new("RGB", (w, h), color=(10, 20, 30))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _now() -> DateTimeValue:
    """Return the current UTC timestamp.

    **Outputs:**
    - datetime: Aware ``datetime`` in UTC.
    """
    return DateTimeValue.now(tz=TimezoneValue.utc)


def _row(name: str = "A", weight: float = 100.0) -> dict:
    """Build a fake `containers` row dict for use as a repository return value.

    **Inputs:**
    - name (str): Container display name.
    - weight (float): Tare weight in grams.

    **Outputs:**
    - dict: Column→value mapping mirroring the ``containers`` table shape.
    """
    return {
        "id": uuid.uuid4(),
        "user_key": "khash",
        "name": name,
        "normalized_name": name.lower(),
        "tare_weight_g": weight,
        "has_photo": False,
        "created_at": _now(),
        "updated_at": _now(),
    }


@pytest.fixture
def client() -> TestClient:
    """TestClient with DB pool, USDA client, and session middleware mocked.

    Any request bearing ``Authorization: Bearer <anything>`` is treated as
    authenticated; requests without the header still hit the real
    middleware and get 401.

    **Outputs:**
    - TestClient: Client bound to the configured app.
    """
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
            """Yield a `MagicMock` DB session with a working async `begin()` ctx."""
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
    """`GET /containers` without a Bearer token returns 401."""
    assert client.get("/containers").status_code == 401


def test_list_containers(client: TestClient) -> None:
    """`GET /containers` returns serialized rows from the repository."""
    rows = [_row("A"), _row("B")]
    with patch(
        "diet_tracker_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.list_for_user = AsyncMock(return_value=rows)
        resp = client.get("/containers", headers=HEADERS)
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["containers"]) == 2
    assert body["containers"][0]["name"] == "A"
    assert body["containers"][0]["has_photo"] is False
    assert "photo" not in body["containers"][0]


def test_create_container(client: TestClient) -> None:
    """`POST /containers` returns 201 with the newly created row."""
    row = _row("Big Pyrex", 412.0)
    with patch(
        "diet_tracker_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.create = AsyncMock(return_value=row)
        resp = client.post(
            "/containers",
            headers=HEADERS,
            json={"name": "Big Pyrex", "tare_weight_g": 412.0},
        )
    assert resp.status_code == 201
    assert resp.json()["name"] == "Big Pyrex"


def test_create_rejects_zero_weight(client: TestClient) -> None:
    """`tare_weight_g=0` is rejected with 422 by request validation."""
    resp = client.post(
        "/containers",
        headers=HEADERS,
        json={"name": "X", "tare_weight_g": 0},
    )
    assert resp.status_code == 422


def test_create_duplicate_name_returns_409(client: TestClient) -> None:
    """A repository `IntegrityError` from a duplicate name surfaces as 409."""
    from sqlalchemy.exc import IntegrityError

    with patch(
        "diet_tracker_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.create = AsyncMock(side_effect=IntegrityError("x", "y", Exception()))
        resp = client.post(
            "/containers",
            headers=HEADERS,
            json={"name": "Dup", "tare_weight_g": 1.0},
        )
    assert resp.status_code == 409


def test_get_container_404_when_missing(client: TestClient) -> None:
    """`GET /containers/{id}` returns 404 when the repository returns `None`."""
    with patch(
        "diet_tracker_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.get_by_id = AsyncMock(return_value=None)
        resp = client.get(f"/containers/{uuid.uuid4()}", headers=HEADERS)
    assert resp.status_code == 404


def test_patch_container(client: TestClient) -> None:
    """`PATCH /containers/{id}` returns 200 with the updated row."""
    row = _row("Renamed", 99.0)
    with patch(
        "diet_tracker_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.update_fields = AsyncMock(return_value=row)
        resp = client.patch(
            f"/containers/{row['id']}",
            headers=HEADERS,
            json={"name": "Renamed", "tare_weight_g": 99.0},
        )
    assert resp.status_code == 200
    assert resp.json()["name"] == "Renamed"


def test_delete_container(client: TestClient) -> None:
    """`DELETE /containers/{id}` returns 204 on a successful delete."""
    with patch(
        "diet_tracker_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.delete = AsyncMock(return_value=True)
        resp = client.delete(f"/containers/{uuid.uuid4()}", headers=HEADERS)
    assert resp.status_code == 204


def test_upload_photo_resizes_and_returns_status(client: TestClient) -> None:
    """Photo upload succeeds with 200 and reports ``has_photo=True``."""
    container_id = uuid.uuid4()
    src = _png_bytes(2000, 1000)
    with patch(
        "diet_tracker_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.set_photo = AsyncMock(return_value=True)
        resp = client.put(
            f"/containers/{container_id}/photo",
            headers=HEADERS,
            files={"file": ("box.png", src, "image/png")},
        )
    assert resp.status_code == 200
    assert resp.json() == {"has_photo": True}


def test_upload_photo_rejects_oversize_via_streaming_cap(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Uploads exceeding `MAX_UPLOAD_BYTES` 413 without invoking the image processor."""
    from diet_tracker_server.routers import containers as containers_module

    monkeypatch.setattr(containers_module, "MAX_UPLOAD_BYTES", 1024)

    container_id = uuid.uuid4()
    big = b"\x00" * 4096  # 4 KB > 1 KB cap
    process_spy = MagicMock()
    with patch(
        "diet_tracker_server.routers.containers.ContainersRepository"
    ) as MockRepo, patch(
        "diet_tracker_server.routers.containers.process_container_photo",
        side_effect=process_spy,
    ):
        instance = MockRepo.return_value
        instance.set_photo = AsyncMock(return_value=True)
        resp = client.put(
            f"/containers/{container_id}/photo",
            headers=HEADERS,
            files={"file": ("big.bin", big, "application/octet-stream")},
        )
    assert resp.status_code == 413
    process_spy.assert_not_called()


def test_upload_photo_rejects_non_image(client: TestClient) -> None:
    """Non-image content type returns 415."""
    container_id = uuid.uuid4()
    with patch(
        "diet_tracker_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.set_photo = AsyncMock(return_value=True)
        resp = client.put(
            f"/containers/{container_id}/photo",
            headers=HEADERS,
            files={"file": ("notes.txt", b"hello", "text/plain")},
        )
    assert resp.status_code == 415


def test_get_photo_returns_jpeg(client: TestClient) -> None:
    """`GET /containers/{id}/photo` returns the JPEG bytes with the correct content type."""
    container_id = uuid.uuid4()
    with patch(
        "diet_tracker_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.get_photo = AsyncMock(return_value=(b"\xff\xd8\xff\xe0", "image/jpeg"))
        resp = client.get(f"/containers/{container_id}/photo", headers=HEADERS)
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "image/jpeg"
    assert resp.content.startswith(b"\xff\xd8")


def test_get_photo_404_when_missing(client: TestClient) -> None:
    """`GET /containers/{id}/photo` returns 404 when no photo is stored."""
    container_id = uuid.uuid4()
    with patch(
        "diet_tracker_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.get_photo = AsyncMock(return_value=None)
        resp = client.get(f"/containers/{container_id}/photo", headers=HEADERS)
    assert resp.status_code == 404


def test_delete_photo(client: TestClient) -> None:
    """`DELETE /containers/{id}/photo` returns 204 when the row is cleared."""
    container_id = uuid.uuid4()
    with patch(
        "diet_tracker_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.clear_photo = AsyncMock(return_value=True)
        resp = client.delete(f"/containers/{container_id}/photo", headers=HEADERS)
    assert resp.status_code == 204
