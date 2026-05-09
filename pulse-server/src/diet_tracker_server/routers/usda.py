from __future__ import annotations

from fastapi import APIRouter, Depends, Query

from diet_tracker_server.auth import require_api_key
from diet_tracker_server.models import USDAFoodResult, USDASearchResponse

router = APIRouter(dependencies=[Depends(require_api_key)])


# Summary: Proxies USDA food search and returns normalized diet records.
# Parameters:
# - query (str): Search phrase sent to USDA FoodData Central.
# - limit (int): Maximum number of food matches to return.
# Returns:
# - USDASearchResponse: Normalized food search results.
# Raises/Throws:
# - RuntimeError: Raised if the USDA client is not initialized.
# - httpx.HTTPError: Raised when USDA requests fail.
@router.get("/usda/search", response_model=USDASearchResponse)
async def search_usda(
    query: str = Query(..., alias="q", min_length=1),
    limit: int = Query(default=5, ge=1, le=25),
) -> USDASearchResponse:
    from diet_tracker_server.app import get_usda_client

    client = get_usda_client()
    results = await client.search(query, page_size=limit)
    return USDASearchResponse(results=[USDAFoodResult(**row) for row in results])
