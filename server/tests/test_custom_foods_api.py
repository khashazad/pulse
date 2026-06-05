"""HTTP unit tests for the `/custom-foods` router.

Covers list, create (201 via the upsert service), patch (200 + 404 +
409 duplicate), and delete (204 + 404 + 409 referenced). The DB and auth
middleware are mocked via the shared ``rest_client`` fixture; the service
and repository are patched at the router module level, so these tests need
no database.
"""

from __future__ import annotations

import uuid
from datetime import UTC
from datetime import datetime as DateTimeValue
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient
from sqlalchemy.exc import IntegrityError

AUTH_HEADERS = {"Authorization": "Bearer tok"}


def _now() -> DateTimeValue:
    """Return the current UTC timestamp.

    **Outputs:**
    - datetime: Aware ``datetime`` in UTC.
    """
    return DateTimeValue.now(tz=UTC)


def _row(name: str = "My Wrap", basis: str = "per_serving") -> dict:
    """Build a fake `custom_foods` row dict for repository/service return values.

    **Inputs:**
    - name (str): Custom-food display name.
    - basis (str): Macro basis indicator.

    **Outputs:**
    - dict: Column→value mapping mirroring the ``custom_foods`` table shape.
    """
    return {
        "id": uuid.uuid4(),
        "user_key": "khash",
        "name": name,
        "normalized_name": name.lower(),
        "basis": basis,
        "serving_size": 1.0,
        "serving_size_unit": "wrap",
        "calories": 350,
        "protein_g": 20.0,
        "carbs_g": 30.0,
        "fat_g": 15.0,
        "source": "manual",
        "notes": None,
        "created_at": _now(),
        "updated_at": _now(),
    }


def test_unauthenticated_rejected(rest_client: TestClient) -> None:
    """`GET /custom-foods` without a Bearer token returns 401."""
    assert rest_client.get("/custom-foods").status_code == 401


def test_list_custom_foods(rest_client: TestClient) -> None:
    """`GET /custom-foods` returns serialized rows from the repository."""
    with patch("pulse_server.routers.custom_foods.CustomFoodsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.list_for_user = AsyncMock(return_value=[_row("A"), _row("B")])
        resp = rest_client.get("/custom-foods", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["custom_foods"]) == 2
    assert body["custom_foods"][0]["name"] == "A"


def test_create_custom_food(rest_client: TestClient) -> None:
    """`POST /custom-foods` returns 201 with the upserted row."""
    row = _row("Granola", basis="per_100g")
    with patch(
        "pulse_server.routers.custom_foods.upsert_custom_food_and_remember",
        new_callable=AsyncMock,
    ) as upsert:
        upsert.return_value = row
        resp = rest_client.post(
            "/custom-foods",
            headers=AUTH_HEADERS,
            json={
                "name": "Granola",
                "basis": "per_100g",
                "calories": 450,
                "protein_g": 10.0,
                "carbs_g": 60.0,
                "fat_g": 18.0,
            },
        )
    assert resp.status_code == 201
    assert resp.json()["name"] == "Granola"


def test_patch_custom_food_200(rest_client: TestClient) -> None:
    """`PATCH /custom-foods/{id}` returns 200 with the updated row."""
    row = _row("Renamed")
    with patch("pulse_server.routers.custom_foods.CustomFoodsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.update_fields = AsyncMock(return_value=row)
        resp = rest_client.patch(
            f"/custom-foods/{row['id']}",
            headers=AUTH_HEADERS,
            json={"name": "Renamed", "calories": 360},
        )
    assert resp.status_code == 200
    assert resp.json()["name"] == "Renamed"


def test_patch_custom_food_404(rest_client: TestClient) -> None:
    """`PATCH /custom-foods/{id}` returns 404 when the row is missing."""
    with patch("pulse_server.routers.custom_foods.CustomFoodsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.update_fields = AsyncMock(return_value=None)
        resp = rest_client.patch(
            f"/custom-foods/{uuid.uuid4()}",
            headers=AUTH_HEADERS,
            json={"calories": 1},
        )
    assert resp.status_code == 404


def test_patch_custom_food_duplicate_name_returns_409(rest_client: TestClient) -> None:
    """A repository `IntegrityError` on update surfaces as 409."""
    with patch("pulse_server.routers.custom_foods.CustomFoodsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.update_fields = AsyncMock(side_effect=IntegrityError("x", "y", Exception()))
        resp = rest_client.patch(
            f"/custom-foods/{uuid.uuid4()}",
            headers=AUTH_HEADERS,
            json={"name": "Dup"},
        )
    assert resp.status_code == 409


def test_delete_custom_food_204(rest_client: TestClient) -> None:
    """`DELETE /custom-foods/{id}` returns 204 on a successful delete."""
    with patch("pulse_server.routers.custom_foods.CustomFoodsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.delete = AsyncMock(return_value=True)
        resp = rest_client.delete(f"/custom-foods/{uuid.uuid4()}", headers=AUTH_HEADERS)
    assert resp.status_code == 204


def test_delete_custom_food_404(rest_client: TestClient) -> None:
    """`DELETE /custom-foods/{id}` returns 404 when nothing was deleted."""
    with patch("pulse_server.routers.custom_foods.CustomFoodsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.delete = AsyncMock(return_value=False)
        resp = rest_client.delete(f"/custom-foods/{uuid.uuid4()}", headers=AUTH_HEADERS)
    assert resp.status_code == 404


def test_delete_custom_food_referenced_returns_409(rest_client: TestClient) -> None:
    """A foreign-key `IntegrityError` on delete surfaces as 409."""
    with patch("pulse_server.routers.custom_foods.CustomFoodsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.delete = AsyncMock(side_effect=IntegrityError("x", "y", Exception()))
        resp = rest_client.delete(f"/custom-foods/{uuid.uuid4()}", headers=AUTH_HEADERS)
    assert resp.status_code == 409
