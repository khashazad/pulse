from __future__ import annotations

from typing import Any

import httpx


# Summary: Converts USDA food payloads into the diet-tracker-server macro schema.
# Parameters:
# - raw (dict[str, Any]): Raw USDA food item payload from search or detail endpoints.
# Returns:
# - dict[str, Any]: Normalized nutrient record with macros and serving fields.
# Raises/Throws:
# - ValueError: Raised when nutrient numeric values cannot be coerced to floats.
def normalize_food_nutrients(raw: dict[str, Any]) -> dict[str, Any]:
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
            result["calories"] = int(round(number))
        elif nutrient_id == 1003 or name == "protein":
            result["protein_g"] = number
        elif nutrient_id == 1005 or "carbohydrate" in name:
            result["carbs_g"] = number
        elif nutrient_id == 1004 or "total lipid" in name or name == "fat":
            result["fat_g"] = number

    return result


class USDAClient:
    # Summary: Initializes an async USDA API client with shared HTTP settings.
    # Parameters:
    # - api_key (str): USDA FoodData Central API key used for authenticated requests.
    # Returns:
    # - None: Initializes instance attributes and async HTTP client state.
    # Raises/Throws:
    # - None: Initialization does not perform network calls.
    def __init__(self, api_key: str) -> None:
        self.api_key = api_key
        self._client = httpx.AsyncClient(
            base_url="https://api.nal.usda.gov/fdc/v1",
            timeout=30.0,
        )

    # Summary: Searches USDA foods by phrase and normalizes returned nutrient records.
    # Parameters:
    # - query (str): Free-text search query sent to USDA's search endpoint.
    # - page_size (int): Maximum number of foods to return.
    # Returns:
    # - list[dict[str, Any]]: Normalized macro entries for matching foods.
    # Raises/Throws:
    # - httpx.HTTPError: Raised when the USDA request fails or returns non-2xx status.
    async def search(self, query: str, page_size: int = 5) -> list[dict[str, Any]]:
        response = await self._client.post(
            "/foods/search",
            params={"api_key": self.api_key},
            json={"query": query, "pageSize": page_size},
        )
        response.raise_for_status()
        data = response.json()
        return [normalize_food_nutrients(item) for item in data.get("foods", [])]

    # Summary: Fetches one USDA food by FDC ID and normalizes the nutrient payload.
    # Parameters:
    # - fdc_id (int): USDA FoodData Central identifier for the requested food.
    # Returns:
    # - dict[str, Any]: Normalized nutrient record for the food item.
    # Raises/Throws:
    # - httpx.HTTPError: Raised when the USDA request fails or returns non-2xx status.
    async def get_food(self, fdc_id: int) -> dict[str, Any]:
        response = await self._client.get(
            f"/food/{fdc_id}",
            params={"api_key": self.api_key},
        )
        response.raise_for_status()
        return normalize_food_nutrients(response.json())

    # Summary: Closes the underlying async HTTP client and releases network resources.
    # Parameters:
    # - None: Operates on the instance HTTP client state.
    # Returns:
    # - None: Completes client shutdown.
    # Raises/Throws:
    # - httpx.HTTPError: Raised if client shutdown encounters transport errors.
    async def close(self) -> None:
        await self._client.aclose()
