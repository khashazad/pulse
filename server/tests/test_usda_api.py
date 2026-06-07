"""HTTP unit tests for the `/usda/search` proxy router.

Covers the happy path (200 with normalized results from the injected
client), the per-user rate-limit 429, and request-validation rejections
(empty / over-long query). The DB and auth middleware are mocked via the
shared ``rest_client`` fixture; the USDA client is supplied via a FastAPI
dependency override so no outbound HTTP occurs.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

AUTH_HEADERS = {"Authorization": "Bearer tok"}


def _candidate() -> dict:
    """Build one normalized USDA search-result row.

    **Outputs:**
    - dict: Normalized macro row matching ``USDAFoodResult`` fields.
    """
    return {
        "fdc_id": 171287,
        "description": "Egg, whole, raw, fresh",
        "calories": 143,
        "protein_g": 12.56,
        "carbs_g": 0.72,
        "fat_g": 9.51,
        "serving_size": 50.0,
        "serving_size_unit": "g",
        "data_type": "Foundation",
        "brand_owner": None,
    }


def _override_usda_client(results: list[dict]):
    """Return a context manager that overrides the USDA client dependency.

    **Inputs:**
    - results (list[dict]): Rows the stub client's ``search`` returns.

    **Outputs:**
    - A context manager that installs the override on the app and removes it on
      exit.
    """
    from contextlib import contextmanager

    from pulse_server.app import app
    from pulse_server.usda_provider import get_usda_client

    @contextmanager
    def _ctx():
        client = AsyncMock()
        client.search = AsyncMock(return_value=results)
        app.dependency_overrides[get_usda_client] = lambda: client
        try:
            yield
        finally:
            app.dependency_overrides.pop(get_usda_client, None)

    return _ctx()


def test_unauthenticated_rejected(rest_client: TestClient) -> None:
    """`GET /usda/search` without a Bearer token returns 401."""
    assert rest_client.get("/usda/search?q=egg").status_code == 401


def test_search_usda_200(rest_client: TestClient) -> None:
    """`GET /usda/search?q=...` returns normalized results from the injected client."""
    with _override_usda_client([_candidate()]):
        resp = rest_client.get("/usda/search?q=egg&limit=3", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["results"]) == 1
    assert body["results"][0]["fdc_id"] == 171287
    assert body["results"][0]["calories"] == 143


def test_search_usda_rate_limited_returns_429(rest_client: TestClient) -> None:
    """When the per-user rate limiter denies the request, the route returns 429."""
    with (
        _override_usda_client([_candidate()]),
        patch("pulse_server.routers.usda._usda_rate_limiter.allow", return_value=False),
    ):
        resp = rest_client.get("/usda/search?q=egg", headers=AUTH_HEADERS)
    assert resp.status_code == 429


def test_search_usda_rejects_empty_query(rest_client: TestClient) -> None:
    """An empty `q` is rejected with 422 by request validation."""
    resp = rest_client.get("/usda/search?q=", headers=AUTH_HEADERS)
    assert resp.status_code == 422


def test_search_usda_rejects_overlong_query(rest_client: TestClient) -> None:
    """A query longer than the cap is rejected with 422 by request validation."""
    resp = rest_client.get(f"/usda/search?q={'x' * 200}", headers=AUTH_HEADERS)
    assert resp.status_code == 422


def test_search_usda_includes_disambiguation_fields(rest_client: TestClient) -> None:
    """`GET /usda/search` round-trips data_type/brand_owner from the client rows."""
    with _override_usda_client([_candidate()]):
        resp = rest_client.get("/usda/search?q=egg", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    row = resp.json()["results"][0]
    assert row["data_type"] == "Foundation"
    assert row["brand_owner"] is None
