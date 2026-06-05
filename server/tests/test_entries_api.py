"""HTTP unit tests for the `/entries` router.

Covers create (201 happy path + 422 cross-tenant custom food), list by
date (200 with totals), and delete (204 + 404). The DB and auth middleware
are mocked via the shared ``rest_client`` fixture; the service and
repository are patched at the router module level, so these tests need no
database.
"""

from __future__ import annotations

import uuid
from datetime import UTC
from datetime import date as DateValue
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


def _entry_row(calories: int = 140) -> dict:
    """Build a fake `food_entries` row dict for repository/service return values.

    **Inputs:**
    - calories (int): Entry calorie value.

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
        "meal_id": None,
        "meal_name": None,
        "consumed_at": _now(),
        "created_at": _now(),
    }


def test_unauthenticated_rejected(rest_client: TestClient) -> None:
    """`GET /entries?date=...` without a Bearer token returns 401."""
    assert rest_client.get("/entries?date=2026-01-01").status_code == 401


def test_create_entries_201(rest_client: TestClient) -> None:
    """`POST /entries` returns 201 with the created entries plus daily totals."""
    created = [_entry_row(140)]
    with patch(
        "pulse_server.routers.entries.create_entries_with_side_effects",
        new_callable=AsyncMock,
    ) as create:
        create.return_value = (created, created)
        resp = rest_client.post(
            "/entries",
            headers=AUTH_HEADERS,
            json={
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
                ]
            },
        )
    assert resp.status_code == 201
    body = resp.json()
    assert len(body["entries"]) == 1
    assert body["daily_totals"]["calories"] == 140


def test_create_entries_cross_tenant_returns_422(rest_client: TestClient) -> None:
    """A `CrossTenantReferenceError` from the service surfaces as 422."""
    from pulse_server.services.custom_foods_service import CrossTenantReferenceError

    with patch(
        "pulse_server.routers.entries.create_entries_with_side_effects",
        new_callable=AsyncMock,
    ) as create:
        create.side_effect = CrossTenantReferenceError("not yours")
        resp = rest_client.post(
            "/entries",
            headers=AUTH_HEADERS,
            json={
                "items": [
                    {
                        "display_name": "Stolen",
                        "quantity_text": "1",
                        "custom_food_id": str(uuid.uuid4()),
                        "calories": 100,
                        "protein_g": 5.0,
                        "carbs_g": 10.0,
                        "fat_g": 2.0,
                    }
                ]
            },
        )
    assert resp.status_code == 422


def test_list_entries_200(rest_client: TestClient) -> None:
    """`GET /entries?date=...` returns the day's entries with aggregate totals."""
    rows = [_entry_row(140), _entry_row(60)]
    with patch("pulse_server.routers.entries.EntriesRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.list_entries_by_daily_log_id = AsyncMock(return_value=rows)
        resp = rest_client.get(
            f"/entries?date={DateValue.today().isoformat()}", headers=AUTH_HEADERS
        )
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["entries"]) == 2
    assert body["totals"]["calories"] == 200


def test_delete_entry_204(rest_client: TestClient) -> None:
    """`DELETE /entries/{id}` returns 204 on a successful delete."""
    with patch("pulse_server.routers.entries.EntriesRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.delete_entry = AsyncMock(return_value=True)
        resp = rest_client.delete(f"/entries/{uuid.uuid4()}", headers=AUTH_HEADERS)
    assert resp.status_code == 204


def test_delete_entry_404(rest_client: TestClient) -> None:
    """`DELETE /entries/{id}` returns 404 when no entry was deleted."""
    with patch("pulse_server.routers.entries.EntriesRepository") as MockRepo:
        instance = MockRepo.return_value
        instance.delete_entry = AsyncMock(return_value=False)
        resp = rest_client.delete(f"/entries/{uuid.uuid4()}", headers=AUTH_HEADERS)
    assert resp.status_code == 404
