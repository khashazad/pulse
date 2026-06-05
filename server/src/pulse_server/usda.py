"""USDA FoodData Central client and nutrient normalization.

Defines :func:`normalize_food_nutrients`, which maps the heterogeneous USDA
nutrient payload (search vs detail endpoints) onto the internal macro schema
(calories=1008, protein=1003, carbs=1005, fat=1004 plus serving fields), and
:class:`USDAClient`, an async ``httpx``-backed wrapper around the FDC v1
``/foods/search`` and ``/food/{fdcId}`` endpoints.

Owned at process scope by the FastAPI lifespan (``app.py``) and surfaced to
routers (and the MCP layer) via :mod:`pulse_server.usda_provider`.
"""

from __future__ import annotations

from typing import Any

import httpx


def normalize_food_nutrients(raw: dict[str, Any]) -> dict[str, Any]:
    """Convert a USDA food payload into the pulse-server macro schema.

    Matches nutrients by FDC id first (1008/1003/1005/1004) and falls back to
    name heuristics. Calories are rounded to int; macros are kept as float
    grams.

    **Inputs:**
    - raw (dict[str, Any]): Raw USDA food item payload from search or detail
      endpoints.

    **Outputs:**
    - dict[str, Any]: Normalized nutrient record with macros and serving fields.

    **Exceptions:**
    - ValueError: Raised when nutrient numeric values cannot be coerced to floats.
    """
    nutrients = raw.get("foodNutrients") or []
    result: dict[str, Any] = {
        "fdc_id": raw.get("fdcId"),
        "description": raw.get("description") or raw.get("lowercaseDescription") or "Unknown food",
        "calories": 0,
        "protein_g": 0.0,
        "carbs_g": 0.0,
        "fat_g": 0.0,
        "serving_size": raw.get("servingSize"),
        "serving_size_unit": raw.get("servingSizeUnit") or raw.get("householdServingFullText"),
    }

    for nutrient in nutrients:
        meta = nutrient.get("nutrient") or {}
        nutrient_id = nutrient.get("nutrientId") or meta.get("id")
        name = str(nutrient.get("nutrientName") or meta.get("name") or "").lower()
        value = nutrient.get("value")
        if value is None:
            value = nutrient.get("amount")
        if value is None:
            continue

        number = float(value)
        if nutrient_id == 1008 or name.startswith("energy"):
            result["calories"] = round(number)
        elif nutrient_id == 1003 or name == "protein":
            result["protein_g"] = number
        elif nutrient_id == 1005 or "carbohydrate" in name:
            result["carbs_g"] = number
        elif nutrient_id == 1004 or "total lipid" in name or name == "fat":
            result["fat_g"] = number

    return result


class USDAClient:
    """Async wrapper around the USDA FoodData Central v1 API.

    Holds a shared ``httpx.AsyncClient`` configured with the FDC base URL and
    a 30 s timeout, and exposes ``search``/``get_food`` helpers that already
    apply :func:`normalize_food_nutrients` to responses.
    """

    def __init__(self, api_key: str) -> None:
        """Initialize an async USDA API client with shared HTTP settings.

        **Inputs:**
        - api_key (str): USDA FoodData Central API key used for authenticated
          requests.
        """
        self.api_key = api_key
        self._client = httpx.AsyncClient(
            base_url="https://api.nal.usda.gov/fdc/v1",
            timeout=30.0,
        )

    async def search(self, query: str, page_size: int = 5) -> list[dict[str, Any]]:
        """Search USDA foods by phrase and normalize returned nutrient records.

        **Inputs:**
        - query (str): Free-text search query sent to USDA's search endpoint.
        - page_size (int): Maximum number of foods to return.

        **Outputs:**
        - list[dict[str, Any]]: Normalized macro entries for matching foods.

        **Exceptions:**
        - httpx.HTTPError: Raised when the USDA request fails or returns
          non-2xx status.
        """
        response = await self._client.post(
            "/foods/search",
            params={"api_key": self.api_key},
            json={"query": query, "pageSize": page_size},
        )
        response.raise_for_status()
        data = response.json()
        return [normalize_food_nutrients(item) for item in data.get("foods", [])]

    async def get_food(self, fdc_id: int) -> dict[str, Any]:
        """Fetch one USDA food by FDC id and normalize the nutrient payload.

        **Inputs:**
        - fdc_id (int): USDA FoodData Central identifier for the requested food.

        **Outputs:**
        - dict[str, Any]: Normalized nutrient record for the food item.

        **Exceptions:**
        - httpx.HTTPError: Raised when the USDA request fails or returns
          non-2xx status.
        """
        response = await self._client.get(
            f"/food/{fdc_id}",
            params={"api_key": self.api_key},
        )
        response.raise_for_status()
        return normalize_food_nutrients(response.json())

    async def close(self) -> None:
        """Close the underlying async HTTP client and release network resources.

        **Exceptions:**
        - httpx.HTTPError: Raised if client shutdown encounters transport errors.
        """
        await self._client.aclose()
