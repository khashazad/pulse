from __future__ import annotations

import io
import os
import uuid
from datetime import datetime as DateTimeValue
from datetime import timezone as TimezoneValue
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient
from PIL import Image

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test")
os.environ.setdefault("API_KEY", "test-key")


def _png_bytes(w: int, h: int) -> bytes:
    img = Image.new("RGB", (w, h), color=(10, 20, 30))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _now() -> DateTimeValue:
    return DateTimeValue.now(tz=TimezoneValue.utc)


def _row(name: str = "A", weight: float = 100.0) -> dict:
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
    with patch("nutrition_server.db.init_pool", new_callable=AsyncMock), patch(
        "nutrition_server.db.bootstrap_schema", new_callable=AsyncMock
    ), patch("nutrition_server.db.close_pool", new_callable=AsyncMock), patch(
        "nutrition_server.usda.USDAClient"
    ) as mock_usda_client:
        mock_usda_client.return_value.close = AsyncMock()
        from nutrition_server.app import app

        with TestClient(app) as test_client:
            yield test_client


HEADERS = {"X-API-Key": "test-key"}


def test_unauthenticated_rejected(client: TestClient) -> None:
    assert client.get("/containers").status_code == 401


def test_list_containers(client: TestClient) -> None:
    rows = [_row("A"), _row("B")]
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
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
    row = _row("Big Pyrex", 412.0)
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
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
    resp = client.post(
        "/containers",
        headers=HEADERS,
        json={"name": "X", "tare_weight_g": 0},
    )
    assert resp.status_code == 422


def test_create_duplicate_name_returns_409(client: TestClient) -> None:
    from sqlalchemy.exc import IntegrityError

    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
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
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.get_by_id = AsyncMock(return_value=None)
        resp = client.get(f"/containers/{uuid.uuid4()}", headers=HEADERS)
    assert resp.status_code == 404


def test_patch_container(client: TestClient) -> None:
    row = _row("Renamed", 99.0)
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
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
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.delete = AsyncMock(return_value=True)
        resp = client.delete(f"/containers/{uuid.uuid4()}", headers=HEADERS)
    assert resp.status_code == 204


def test_upload_photo_resizes_and_returns_status(client: TestClient) -> None:
    container_id = uuid.uuid4()
    src = _png_bytes(2000, 1000)
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
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


def test_upload_photo_rejects_non_image(client: TestClient) -> None:
    container_id = uuid.uuid4()
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
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
    container_id = uuid.uuid4()
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.get_photo = AsyncMock(return_value=(b"\xff\xd8\xff\xe0", "image/jpeg"))
        resp = client.get(f"/containers/{container_id}/photo", headers=HEADERS)
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "image/jpeg"
    assert resp.content.startswith(b"\xff\xd8")


def test_get_photo_404_when_missing(client: TestClient) -> None:
    container_id = uuid.uuid4()
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.get_photo = AsyncMock(return_value=None)
        resp = client.get(f"/containers/{container_id}/photo", headers=HEADERS)
    assert resp.status_code == 404


def test_delete_photo(client: TestClient) -> None:
    container_id = uuid.uuid4()
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.clear_photo = AsyncMock(return_value=True)
        resp = client.delete(f"/containers/{container_id}/photo", headers=HEADERS)
    assert resp.status_code == 204
