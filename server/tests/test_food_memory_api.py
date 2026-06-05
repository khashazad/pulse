"""HTTP unit tests for the `/food-memory` router.

Covers list, resolve (delegating to the service), USDA upsert, custom
upsert (200 + 404 when the linked custom food is missing), and delete by
name (204 + 404). The DB and auth middleware are mocked via the shared
``rest_client`` fixture; the service and repositories are patched at the
router module level, so these tests need no database.
"""

from __future__ import annotations

import uuid
from datetime import UTC
from datetime import datetime as DateTimeValue
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

AUTH_HEADERS = {"Authorization": "Bearer tok"}


def _now() -> DateTimeValue:
    """Return the current UTC timestamp.

    **Outputs:**
    - datetime: Aware ``datetime`` in UTC.
    """
    return DateTimeValue.now(tz=UTC)


def _usda_row(name: str = "Greek Yogurt") -> dict:
    """Build a fake USDA-backed `food_memory` row dict.

    **Inputs:**
    - name (str): Memory entry display name.

    **Outputs:**
    - dict: Column→value mapping mirroring a USDA-pointer ``food_memory`` row.
    """
    return {
        "id": uuid.uuid4(),
        "user_key": "khash",
        "name": name,
        "normalized_name": name.lower(),
        "usda_fdc_id": 170894,
        "usda_description": "Yogurt, Greek, plain, nonfat",
        "custom_food_id": None,
        "basis": "per_100g",
        "serving_size": 170.0,
        "serving_size_unit": "g",
        "calories": 59,
        "protein_g": 10.2,
        "carbs_g": 3.6,
        "fat_g": 0.4,
        "aliases": [],
        "created_at": _now(),
        "updated_at": _now(),
    }


def _custom_row(name: str = "My Wrap") -> dict:
    """Build a fake custom-food-backed `food_memory` row dict.

    **Inputs:**
    - name (str): Memory entry display name.

    **Outputs:**
    - dict: Column→value mapping mirroring a custom-pointer ``food_memory`` row.
    """
    return {
        "id": uuid.uuid4(),
        "user_key": "khash",
        "name": name,
        "normalized_name": name.lower(),
        "usda_fdc_id": None,
        "usda_description": None,
        "custom_food_id": uuid.uuid4(),
        "basis": None,
        "serving_size": None,
        "serving_size_unit": None,
        "calories": None,
        "protein_g": None,
        "carbs_g": None,
        "fat_g": None,
        "aliases": [],
        "created_at": _now(),
        "updated_at": _now(),
    }


def test_unauthenticated_rejected(rest_client: TestClient) -> None:
    """`GET /food-memory` without a Bearer token returns 401."""
    assert rest_client.get("/food-memory").status_code == 401


def test_list_food_memory(rest_client: TestClient) -> None:
    """`GET /food-memory` returns serialized rows from the repository."""
    with patch("pulse_server.routers.food_memory.FoodMemoryRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.list_for_user = AsyncMock(return_value=[_usda_row("A"), _usda_row("B")])
        resp = rest_client.get("/food-memory", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["entries"]) == 2
    assert body["entries"][0]["usda_fdc_id"] == 170894


def test_resolve_food_returns_service_result(rest_client: TestClient) -> None:
    """`GET /food-memory/resolve` returns the resolved-food payload from the service."""
    from pulse_server.models import ResolvedFood

    with patch(
        "pulse_server.routers.food_memory.resolve_food_by_name",
        new_callable=AsyncMock,
    ) as resolve:
        resolve.return_value = ResolvedFood(
            type="memory_usda",
            name="greek yogurt",
            usda_fdc_id=170894,
            basis="per_100g",
            calories=59,
            protein_g=10.2,
            carbs_g=3.6,
            fat_g=0.4,
        )
        resp = rest_client.get("/food-memory/resolve?name=greek yogurt", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    body = resp.json()
    assert body["type"] == "memory_usda"
    assert body["usda_fdc_id"] == 170894


def test_resolve_food_rejects_empty_name(rest_client: TestClient) -> None:
    """`GET /food-memory/resolve` rejects an empty `name` with 422 validation."""
    resp = rest_client.get("/food-memory/resolve?name=", headers=AUTH_HEADERS)
    assert resp.status_code == 422


def test_remember_food_usda(rest_client: TestClient) -> None:
    """`PUT /food-memory/usda` upserts and returns the USDA-pointer entry."""
    row = _usda_row()
    with patch("pulse_server.routers.food_memory.FoodMemoryRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.upsert_usda = AsyncMock(return_value=row)
        resp = rest_client.put(
            "/food-memory/usda",
            headers=AUTH_HEADERS,
            json={
                "name": "Greek Yogurt",
                "usda_fdc_id": 170894,
                "usda_description": "Yogurt, Greek, plain, nonfat",
                "basis": "per_100g",
                "calories": 59,
                "protein_g": 10.2,
                "carbs_g": 3.6,
                "fat_g": 0.4,
            },
        )
    assert resp.status_code == 200
    assert resp.json()["usda_fdc_id"] == 170894


def test_remember_food_custom_200(rest_client: TestClient) -> None:
    """`PUT /food-memory/custom` upserts a custom-pointer entry when the custom food exists."""
    cf_id = uuid.uuid4()
    row = _custom_row()
    with (
        patch("pulse_server.routers.food_memory.CustomFoodsRepository") as MockCustomRepo,
        patch("pulse_server.routers.food_memory.FoodMemoryRepository") as MockMemoryRepo,
    ):
        MockCustomRepo.return_value.get_by_id = AsyncMock(return_value={"id": cf_id})
        MockMemoryRepo.return_value.upsert_custom = AsyncMock(return_value=row)
        resp = rest_client.put(
            "/food-memory/custom",
            headers=AUTH_HEADERS,
            json={"name": "My Wrap", "custom_food_id": str(cf_id)},
        )
    assert resp.status_code == 200
    assert resp.json()["name"] == "My Wrap"


def test_remember_food_custom_404_when_missing(rest_client: TestClient) -> None:
    """`PUT /food-memory/custom` returns 404 when the linked custom food does not exist."""
    with patch("pulse_server.routers.food_memory.CustomFoodsRepository") as MockCustomRepo:
        MockCustomRepo.return_value.get_by_id = AsyncMock(return_value=None)
        resp = rest_client.put(
            "/food-memory/custom",
            headers=AUTH_HEADERS,
            json={"name": "Ghost", "custom_food_id": str(uuid.uuid4())},
        )
    assert resp.status_code == 404


def test_forget_food_204(rest_client: TestClient) -> None:
    """`DELETE /food-memory?name=...` returns 204 when a row is deleted."""
    with patch("pulse_server.routers.food_memory.FoodMemoryRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.delete_by_name = AsyncMock(return_value=True)
        resp = rest_client.delete("/food-memory?name=greek yogurt", headers=AUTH_HEADERS)
    assert resp.status_code == 204


def test_forget_food_404(rest_client: TestClient) -> None:
    """`DELETE /food-memory?name=...` returns 404 when no row matches."""
    with patch("pulse_server.routers.food_memory.FoodMemoryRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.delete_by_name = AsyncMock(return_value=False)
        resp = rest_client.delete("/food-memory?name=unknown", headers=AUTH_HEADERS)
    assert resp.status_code == 404
