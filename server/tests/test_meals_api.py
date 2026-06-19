"""HTTP unit tests for the `/meals` router.

Covers list, create (201 + 409 duplicate), get (200 + 404), patch (200 +
404 + 409 duplicate), delete (204 + 404), add-item (201 + the two 422
validation branches + 404 missing meal + 422 cross-tenant custom food),
delete-item (204 + 404 missing meal + 404 missing item), and log
(happy path + naive-`consumed_at` normalization). The DB and auth
middleware are mocked via the shared ``rest_client`` fixture; service and
repository calls are patched at the router module level, so these tests
need no database.
"""

from __future__ import annotations

import uuid
from datetime import UTC
from datetime import datetime as DateTimeValue
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient
from sqlalchemy.exc import IntegrityError

# Header that makes a request pass the mocked session middleware in the shared
# ``rest_client`` fixture (see tests/conftest.py).
AUTH_HEADERS = {"Authorization": "Bearer tok"}


def _now() -> DateTimeValue:
    """Return the current UTC timestamp.

    **Outputs:**
    - datetime: Aware ``datetime`` in UTC.
    """
    return DateTimeValue.now(tz=UTC)


def _meal_row(name: str = "Breakfast") -> dict:
    """Build a fake `meals` row dict for repository/service return values.

    **Inputs:**
    - name (str): Meal display name.

    **Outputs:**
    - dict: Column→value mapping mirroring the ``meals`` table shape.
    """
    return {
        "id": uuid.uuid4(),
        "user_key": "khash",
        "name": name,
        "normalized_name": name.lower(),
        "notes": None,
        "aliases": [],
        "created_at": _now(),
        "updated_at": _now(),
    }


def _item_row(meal_id: uuid.UUID, position: int = 0) -> dict:
    """Build a fake `meal_items` row dict.

    **Inputs:**
    - meal_id (UUID): Owning meal id.
    - position (int): Ordinal position within the meal.

    **Outputs:**
    - dict: Column→value mapping mirroring the ``meal_items`` table shape.
    """
    return {
        "id": uuid.uuid4(),
        "meal_id": meal_id,
        "position": position,
        "display_name": "Eggs",
        "quantity_text": "2 large",
        "normalized_quantity_value": 2.0,
        "normalized_quantity_unit": "large",
        "usda_fdc_id": 123,
        "usda_description": "Egg, whole",
        "custom_food_id": None,
        "calories": 140,
        "protein_g": 12.0,
        "carbs_g": 1.0,
        "fat_g": 10.0,
        "created_at": _now(),
    }


def _summary_row(name: str = "Breakfast", item_count: int = 2) -> dict:
    """Build a fake `list_meals` aggregate row dict.

    **Inputs:**
    - name (str): Meal name.
    - item_count (int): Number of items in the meal.

    **Outputs:**
    - dict: Mapping of the aggregate columns ``list_meals`` returns.
    """
    return {
        "id": uuid.uuid4(),
        "name": name,
        "normalized_name": name.lower(),
        "notes": None,
        "aliases": [],
        "item_count": item_count,
        "total_calories": 220,
        "total_protein_g": 15.0,
        "total_carbs_g": 16.0,
        "total_fat_g": 11.0,
    }


def test_unauthenticated_rejected(rest_client: TestClient) -> None:
    """`GET /meals` without a Bearer token returns 401."""
    assert rest_client.get("/meals").status_code == 401


def test_list_meals(rest_client: TestClient) -> None:
    """`GET /meals` returns per-meal summaries from the repository."""
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.list_meals = AsyncMock(
            return_value=[_summary_row("Breakfast"), _summary_row("Lunch")]
        )
        resp = rest_client.get("/meals", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["meals"]) == 2
    assert body["meals"][0]["item_count"] == 2
    assert body["meals"][0]["total_calories"] == 220


def test_create_meal(rest_client: TestClient) -> None:
    """`POST /meals` returns 201 with the created meal and its items."""
    meal = _meal_row("Dinner")
    items = [_item_row(meal["id"])]
    with patch(
        "pulse_server.routers.meals.create_meal_with_items",
        new_callable=AsyncMock,
    ) as create:
        create.return_value = (meal, items)
        resp = rest_client.post(
            "/meals",
            headers=AUTH_HEADERS,
            json={
                "name": "Dinner",
                "items": [
                    {
                        "display_name": "Eggs",
                        "quantity_text": "2 large",
                        "usda_fdc_id": 123,
                        "usda_description": "Egg, whole",
                        "calories": 140,
                        "protein_g": 12.0,
                        "carbs_g": 1.0,
                        "fat_g": 10.0,
                    }
                ],
            },
        )
    assert resp.status_code == 201
    body = resp.json()
    assert body["name"] == "Dinner"
    assert len(body["items"]) == 1


def test_create_meal_duplicate_name_returns_409(rest_client: TestClient) -> None:
    """A repository `IntegrityError` on create surfaces as 409."""
    with patch(
        "pulse_server.routers.meals.create_meal_with_items",
        new_callable=AsyncMock,
    ) as create:
        create.side_effect = IntegrityError("x", "y", Exception())
        resp = rest_client.post(
            "/meals",
            headers=AUTH_HEADERS,
            json={
                "name": "Dup",
                "items": [
                    {
                        "display_name": "x",
                        "quantity_text": "1",
                        "usda_fdc_id": 1,
                        "usda_description": "x",
                        "calories": 1,
                        "protein_g": 0,
                        "carbs_g": 0,
                        "fat_g": 0,
                    }
                ],
            },
        )
    assert resp.status_code == 409


def test_get_meal_200(rest_client: TestClient) -> None:
    """`GET /meals/{id}` returns 200 with the meal and its items."""
    meal = _meal_row("Brunch")
    items = [_item_row(meal["id"])]
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.get_meal = AsyncMock(return_value=meal)
        instance.list_items = AsyncMock(return_value=items)
        resp = rest_client.get(f"/meals/{meal['id']}", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    assert resp.json()["name"] == "Brunch"


def test_get_meal_404(rest_client: TestClient) -> None:
    """`GET /meals/{id}` returns 404 when the meal is missing."""
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.get_meal = AsyncMock(return_value=None)
        resp = rest_client.get(f"/meals/{uuid.uuid4()}", headers=AUTH_HEADERS)
    assert resp.status_code == 404


def test_patch_meal_200(rest_client: TestClient) -> None:
    """`PATCH /meals/{id}` returns 200 with the updated meal."""
    meal = _meal_row("Renamed")
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.update_meal = AsyncMock(return_value=meal)
        instance.list_items = AsyncMock(return_value=[])
        resp = rest_client.patch(
            f"/meals/{meal['id']}",
            headers=AUTH_HEADERS,
            json={"name": "Renamed"},
        )
    assert resp.status_code == 200
    assert resp.json()["name"] == "Renamed"


def test_patch_meal_404(rest_client: TestClient) -> None:
    """`PATCH /meals/{id}` returns 404 when the meal is missing."""
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.update_meal = AsyncMock(return_value=None)
        resp = rest_client.patch(
            f"/meals/{uuid.uuid4()}",
            headers=AUTH_HEADERS,
            json={"name": "Ghost"},
        )
    assert resp.status_code == 404


def test_patch_meal_duplicate_name_returns_409(rest_client: TestClient) -> None:
    """A repository `IntegrityError` on update surfaces as 409."""
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.update_meal = AsyncMock(side_effect=IntegrityError("x", "y", Exception()))
        resp = rest_client.patch(
            f"/meals/{uuid.uuid4()}",
            headers=AUTH_HEADERS,
            json={"name": "Dup"},
        )
    assert resp.status_code == 409


def test_delete_meal_204(rest_client: TestClient) -> None:
    """`DELETE /meals/{id}` returns 204 on a successful delete."""
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.delete_meal = AsyncMock(return_value=True)
        resp = rest_client.delete(f"/meals/{uuid.uuid4()}", headers=AUTH_HEADERS)
    assert resp.status_code == 204


def test_delete_meal_404(rest_client: TestClient) -> None:
    """`DELETE /meals/{id}` returns 404 when nothing was deleted."""
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.delete_meal = AsyncMock(return_value=False)
        resp = rest_client.delete(f"/meals/{uuid.uuid4()}", headers=AUTH_HEADERS)
    assert resp.status_code == 404


def test_add_meal_item_201(rest_client: TestClient) -> None:
    """`POST /meals/{id}/items` returns 201 with the new item."""
    meal = _meal_row()
    item = _item_row(meal["id"], position=1)
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.get_meal = AsyncMock(return_value=meal)
        instance.next_position = AsyncMock(return_value=1)
        instance.add_meal_item = AsyncMock(return_value=item)
        resp = rest_client.post(
            f"/meals/{meal['id']}/items",
            headers=AUTH_HEADERS,
            json={
                "display_name": "Eggs",
                "quantity_text": "2 large",
                "usda_fdc_id": 123,
                "usda_description": "Egg, whole",
                "calories": 140,
                "protein_g": 12.0,
                "carbs_g": 1.0,
                "fat_g": 10.0,
            },
        )
    assert resp.status_code == 201
    assert resp.json()["display_name"] == "Eggs"


def test_add_meal_item_dual_source_returns_422(rest_client: TestClient) -> None:
    """An item with both `usda_fdc_id` and `custom_food_id` returns 422."""
    resp = rest_client.post(
        f"/meals/{uuid.uuid4()}/items",
        headers=AUTH_HEADERS,
        json={
            "display_name": "Bad",
            "quantity_text": "1",
            "usda_fdc_id": 1,
            "usda_description": "x",
            "custom_food_id": str(uuid.uuid4()),
            "calories": 1,
            "protein_g": 0,
            "carbs_g": 0,
            "fat_g": 0,
        },
    )
    assert resp.status_code == 422


def test_add_meal_item_missing_usda_description_returns_422(rest_client: TestClient) -> None:
    """A USDA item missing `usda_description` returns 422."""
    resp = rest_client.post(
        f"/meals/{uuid.uuid4()}/items",
        headers=AUTH_HEADERS,
        json={
            "display_name": "Bad",
            "quantity_text": "1",
            "usda_fdc_id": 1,
            "calories": 1,
            "protein_g": 0,
            "carbs_g": 0,
            "fat_g": 0,
        },
    )
    assert resp.status_code == 422


def test_add_meal_item_meal_not_found_returns_404(rest_client: TestClient) -> None:
    """`POST /meals/{id}/items` returns 404 when the meal is missing."""
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.get_meal = AsyncMock(return_value=None)
        resp = rest_client.post(
            f"/meals/{uuid.uuid4()}/items",
            headers=AUTH_HEADERS,
            json={
                "display_name": "Eggs",
                "quantity_text": "2",
                "usda_fdc_id": 123,
                "usda_description": "Egg",
                "calories": 140,
                "protein_g": 12.0,
                "carbs_g": 1.0,
                "fat_g": 10.0,
            },
        )
    assert resp.status_code == 404


def test_add_meal_item_cross_tenant_custom_food_returns_422(rest_client: TestClient) -> None:
    """A custom_food_id owned by another user returns 422 via CrossTenantReferenceError."""
    from pulse_server.services.custom_foods_service import CrossTenantReferenceError

    meal = _meal_row()
    with (
        patch("pulse_server.routers.meals.MealsRepository") as MockRepo,
        patch(
            "pulse_server.routers.meals.assert_custom_foods_owned",
            new_callable=AsyncMock,
        ) as assert_owned,
    ):
        instance = MockRepo.return_value
        instance.get_meal = AsyncMock(return_value=meal)
        assert_owned.side_effect = CrossTenantReferenceError("not yours")
        resp = rest_client.post(
            f"/meals/{meal['id']}/items",
            headers=AUTH_HEADERS,
            json={
                "display_name": "Stolen",
                "quantity_text": "1",
                "custom_food_id": str(uuid.uuid4()),
                "calories": 1,
                "protein_g": 0,
                "carbs_g": 0,
                "fat_g": 0,
            },
        )
    assert resp.status_code == 422


def test_delete_meal_item_204(rest_client: TestClient) -> None:
    """`DELETE /meals/{id}/items/{item_id}` returns 204 on success."""
    meal = _meal_row()
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.get_meal = AsyncMock(return_value=meal)
        instance.delete_meal_item = AsyncMock(return_value=True)
        resp = rest_client.delete(f"/meals/{meal['id']}/items/{uuid.uuid4()}", headers=AUTH_HEADERS)
    assert resp.status_code == 204


def test_delete_meal_item_meal_not_found_returns_404(rest_client: TestClient) -> None:
    """`DELETE /meals/{id}/items/{item_id}` returns 404 when the meal is missing."""
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.get_meal = AsyncMock(return_value=None)
        resp = rest_client.delete(
            f"/meals/{uuid.uuid4()}/items/{uuid.uuid4()}", headers=AUTH_HEADERS
        )
    assert resp.status_code == 404


def test_delete_meal_item_item_not_found_returns_404(rest_client: TestClient) -> None:
    """`DELETE /meals/{id}/items/{item_id}` returns 404 when the item is missing."""
    meal = _meal_row()
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.get_meal = AsyncMock(return_value=meal)
        instance.delete_meal_item = AsyncMock(return_value=False)
        resp = rest_client.delete(f"/meals/{meal['id']}/items/{uuid.uuid4()}", headers=AUTH_HEADERS)
    assert resp.status_code == 404


def test_update_meal_item_200(rest_client: TestClient) -> None:
    """`PATCH /meals/{id}/items/{item_id}` returns 200 with the updated item."""
    meal = _meal_row()
    item = _item_row(meal["id"])
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.get_meal = AsyncMock(return_value=meal)
        instance.update_meal_item = AsyncMock(return_value=item)
        resp = rest_client.patch(
            f"/meals/{meal['id']}/items/{item['id']}",
            headers=AUTH_HEADERS,
            json={"quantity_text": "120 g", "calories": 165, "protein_g": 1.5,
                  "carbs_g": 24.0, "fat_g": 1.0, "normalized_quantity_value": 120,
                  "normalized_quantity_unit": "g"},
        )
    assert resp.status_code == 200
    assert resp.json()["display_name"] == "Eggs"
    # Only the mutable fields were forwarded to the repository.
    fields = instance.update_meal_item.await_args.args[2] \
        if len(instance.update_meal_item.await_args.args) > 2 \
        else instance.update_meal_item.await_args.kwargs["fields"]
    assert "usda_fdc_id" not in fields
    assert fields["quantity_text"] == "120 g"


def test_update_meal_item_meal_not_found_returns_404(rest_client: TestClient) -> None:
    """`PATCH /meals/{id}/items/{item_id}` returns 404 when the meal is missing."""
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.get_meal = AsyncMock(return_value=None)
        resp = rest_client.patch(
            f"/meals/{uuid.uuid4()}/items/{uuid.uuid4()}",
            headers=AUTH_HEADERS,
            json={"quantity_text": "1"},
        )
    assert resp.status_code == 404


def test_update_meal_item_item_not_found_returns_404(rest_client: TestClient) -> None:
    """`PATCH /meals/{id}/items/{item_id}` returns 404 when the item is missing."""
    meal = _meal_row()
    with patch("pulse_server.routers.meals.MealsRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.get_meal = AsyncMock(return_value=meal)
        instance.update_meal_item = AsyncMock(return_value=None)
        resp = rest_client.patch(
            f"/meals/{meal['id']}/items/{uuid.uuid4()}",
            headers=AUTH_HEADERS,
            json={"quantity_text": "1"},
        )
    assert resp.status_code == 404


def _entry_row(
    meal_id: uuid.UUID, meal_name: str, calories: int = 140, confirmed: bool = True
) -> dict:
    """Build a fake `food_entries` row dict stamped with a meal link.

    **Inputs:**
    - meal_id (UUID): Stamped meal id.
    - meal_name (str): Stamped meal name.
    - calories (int): Entry calorie value.
    - confirmed (bool): Whether the entry counts toward totals (default ``True``).

    **Outputs:**
    - dict: Column→value mapping mirroring the ``food_entries`` table shape.
    """
    return {
        "id": uuid.uuid4(),
        "daily_log_id": uuid.uuid4(),
        "user_key": "khash",
        "entry_group_id": uuid.uuid4(),
        "display_name": "Eggs",
        "quantity_text": "2 large",
        "normalized_quantity_value": None,
        "normalized_quantity_unit": None,
        "usda_fdc_id": 123,
        "usda_description": "Egg, whole",
        "custom_food_id": None,
        "calories": calories,
        "protein_g": 12.0,
        "carbs_g": 1.0,
        "fat_g": 10.0,
        "meal_id": meal_id,
        "meal_name": meal_name,
        "consumed_at": _now(),
        "created_at": _now(),
        "confirmed": confirmed,
    }


def test_log_meal_happy_path(rest_client: TestClient) -> None:
    """`POST /meals/{id}/log` returns the created entries plus recomputed daily totals."""
    meal_id = uuid.uuid4()
    created = [_entry_row(meal_id, "Breakfast")]
    with patch(
        "pulse_server.routers.meals.log_meal",
        new_callable=AsyncMock,
    ) as log:
        log.return_value = (created, created)
        resp = rest_client.post(f"/meals/{meal_id}/log", headers=AUTH_HEADERS, json={})
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["entries"]) == 1
    assert body["daily_totals"]["calories"] == 140


def test_log_meal_excludes_pending_from_daily_totals(rest_client: TestClient) -> None:
    """`POST /meals/{id}/log` daily totals exclude pending entries already on the day."""
    meal_id = uuid.uuid4()
    created = [_entry_row(meal_id, "Breakfast", calories=140)]
    # The day already holds a pending future-prep entry; it must not inflate totals.
    day_rows = [*created, _entry_row(meal_id, "Breakfast", calories=900, confirmed=False)]
    with patch(
        "pulse_server.routers.meals.log_meal",
        new_callable=AsyncMock,
    ) as log:
        log.return_value = (created, day_rows)
        resp = rest_client.post(f"/meals/{meal_id}/log", headers=AUTH_HEADERS, json={})
    assert resp.status_code == 200
    assert resp.json()["daily_totals"]["calories"] == 140


def test_log_meal_normalizes_naive_consumed_at(rest_client: TestClient) -> None:
    """A naive `consumed_at` is passed to the service as a tz-aware datetime."""
    meal_id = uuid.uuid4()
    created = [_entry_row(meal_id, "Breakfast")]
    with patch(
        "pulse_server.routers.meals.log_meal",
        new_callable=AsyncMock,
    ) as log:
        log.return_value = (created, created)
        resp = rest_client.post(
            f"/meals/{meal_id}/log",
            headers=AUTH_HEADERS,
            json={"consumed_at": "2026-01-15T12:00:00"},
        )
    assert resp.status_code == 200
    # The naive timestamp must have been localized to the configured TZ before
    # reaching the service.
    passed = log.await_args.kwargs["consumed_at"]
    assert passed is not None
    assert passed.tzinfo is not None
