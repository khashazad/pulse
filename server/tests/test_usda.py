"""Unit tests for `usda.normalize_food_nutrients` and `USDAClient`.

Covers both USDA nutrient payload shapes (the flat search-result format
with `nutrientId` + `value`, and the nested-metadata format used in
detail responses) plus the safe zero defaults when no nutrient rows are
present. Also exercises ``USDAClient.search``/``get_food``/``close`` against
an in-memory ``httpx.MockTransport`` (no real network), including the
``raise_for_status`` error path on a non-2xx response.
"""

import httpx
import pytest

from pulse_server.usda import USDAClient, normalize_food_nutrients


def test_normalize_extracts_macros_from_search_result() -> None:
    """Nutrient normalization extracts macros and serving size from search-style payloads."""
    raw = {
        "fdcId": 171287,
        "description": "Egg, whole, raw, fresh",
        "foodNutrients": [
            {"nutrientId": 1008, "value": 143},
            {"nutrientId": 1003, "value": 12.56},
            {"nutrientId": 1005, "value": 0.72},
            {"nutrientId": 1004, "value": 9.51},
        ],
        "servingSize": 50.0,
        "servingSizeUnit": "g",
    }
    result = normalize_food_nutrients(raw)
    assert result["fdc_id"] == 171287
    assert result["calories"] == 143
    assert result["protein_g"] == 12.56
    assert result["fat_g"] == 9.51
    assert result["serving_size"] == 50.0


def test_normalize_handles_nested_nutrient_format() -> None:
    """Normalization supports the nested `nutrient: {id, amount}` payload variant."""
    raw = {
        "fdcId": 173430,
        "description": "Butter, salted",
        "foodNutrients": [
            {"nutrient": {"id": 1008, "name": "Energy"}, "amount": 717},
            {"nutrient": {"id": 1003, "name": "Protein"}, "amount": 0.85},
            {"nutrient": {"id": 1005, "name": "Carbohydrate, by difference"}, "amount": 0.06},
            {"nutrient": {"id": 1004, "name": "Total lipid (fat)"}, "amount": 81.11},
        ],
        "servingSize": 14.2,
        "householdServingFullText": "1 tbsp",
    }
    result = normalize_food_nutrients(raw)
    assert result["calories"] == 717
    assert result["fat_g"] == 81.11
    assert result["serving_size_unit"] == "1 tbsp"


def test_normalize_handles_missing_nutrients() -> None:
    """An empty `foodNutrients` list yields zero defaults rather than raising."""
    raw = {"fdcId": 1, "description": "Mystery food", "foodNutrients": []}
    result = normalize_food_nutrients(raw)
    assert result["calories"] == 0
    assert result["protein_g"] == 0.0


def test_normalize_skips_nutrient_rows_with_no_value() -> None:
    """Nutrient rows whose `value`/`amount` are both absent are skipped (no crash)."""
    raw = {
        "fdcId": 9,
        "description": "Partial",
        "foodNutrients": [
            {"nutrientId": 1008},  # no value, no amount -> skipped
            {"nutrientId": 1003, "value": 7.0},
        ],
    }
    result = normalize_food_nutrients(raw)
    assert result["calories"] == 0  # skipped row left the default
    assert result["protein_g"] == 7.0


def _client_with_transport(handler) -> USDAClient:
    """Build a ``USDAClient`` whose internal httpx client uses a mock transport.

    **Inputs:**
    - handler (Callable[[httpx.Request], httpx.Response]): Request handler the
      ``httpx.MockTransport`` invokes for every outbound call.

    **Outputs:**
    - USDAClient: Client whose ``_client`` is swapped for one bound to the mock
      transport (same base URL, no real network).
    """
    client = USDAClient(api_key="test-key")
    client._client = httpx.AsyncClient(
        base_url="https://api.nal.usda.gov/fdc/v1",
        transport=httpx.MockTransport(handler),
    )
    return client


@pytest.mark.asyncio
async def test_client_search_normalizes_results() -> None:
    """``USDAClient.search`` posts to /foods/search and normalizes each returned food."""

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path.endswith("/foods/search")
        return httpx.Response(
            200,
            json={
                "foods": [
                    {
                        "fdcId": 171287,
                        "description": "Egg, whole, raw",
                        "foodNutrients": [
                            {"nutrientId": 1008, "value": 143},
                            {"nutrientId": 1003, "value": 12.56},
                        ],
                    }
                ]
            },
        )

    client = _client_with_transport(handler)
    try:
        results = await client.search("egg", page_size=3)
    finally:
        await client.close()
    assert len(results) == 1
    assert results[0]["fdc_id"] == 171287
    assert results[0]["calories"] == 143


@pytest.mark.asyncio
async def test_client_get_food_normalizes_detail() -> None:
    """``USDAClient.get_food`` fetches /food/{id} and normalizes the detail payload."""

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path.endswith("/food/173430")
        return httpx.Response(
            200,
            json={
                "fdcId": 173430,
                "description": "Butter, salted",
                "foodNutrients": [
                    {"nutrient": {"id": 1008, "name": "Energy"}, "amount": 717},
                ],
            },
        )

    client = _client_with_transport(handler)
    try:
        detail = await client.get_food(173430)
    finally:
        await client.close()
    assert detail["fdc_id"] == 173430
    assert detail["calories"] == 717


@pytest.mark.asyncio
async def test_client_search_raises_on_http_error() -> None:
    """A non-2xx USDA response makes ``search`` raise via ``raise_for_status``."""

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(429, json={"error": "rate limited"})

    client = _client_with_transport(handler)
    try:
        with pytest.raises(httpx.HTTPStatusError):
            await client.search("egg")
    finally:
        await client.close()


def test_normalize_passes_through_data_type_and_brand_owner() -> None:
    """`normalize_food_nutrients` surfaces USDA's dataType/brandOwner fields."""
    raw = {
        "fdcId": 2646170,
        "description": "CHICKEN BREAST",
        "dataType": "Branded",
        "brandOwner": "Tyson Foods Inc.",
        "foodNutrients": [],
    }
    result = normalize_food_nutrients(raw)
    assert result["data_type"] == "Branded"
    assert result["brand_owner"] == "Tyson Foods Inc."


def test_normalize_defaults_data_type_and_brand_owner_to_none() -> None:
    """Foods without dataType/brandOwner normalize to explicit None fields."""
    raw = {"fdcId": 171077, "description": "Chicken breast, raw", "foodNutrients": []}
    result = normalize_food_nutrients(raw)
    assert result["data_type"] is None
    assert result["brand_owner"] is None
