"""Thin proxy router over the USDA FoodData Central search API.

Exposes ``GET /usda/search`` which forwards the user's query to the configured
:class:`USDAClient` and returns normalized macro-mapped results. Used by the
iOS client only when local food memory misses.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query

from diet_tracker_server.auth import require_session
from diet_tracker_server.models import USDAFoodResult, USDASearchResponse

router = APIRouter(dependencies=[Depends(require_session)])


@router.get("/usda/search", response_model=USDASearchResponse)
async def search_usda(
    query: str = Query(..., alias="q", min_length=1),
    limit: int = Query(default=5, ge=1, le=25),
) -> USDASearchResponse:
    """Proxy a search to USDA FoodData Central and return normalized diet records.

    **Inputs:**
    - query (str): Search phrase (query alias ``q``); must be non-empty.
    - limit (int): Maximum number of food matches to return, in ``[1, 25]``.

    **Outputs:**
    - USDASearchResponse: Normalized food search results with diet macros mapped.

    **Exceptions:**
    - RuntimeError: Raised if the USDA client is not initialized.
    - httpx.HTTPError: Raised when the upstream USDA request fails.
    """
    from diet_tracker_server.app import get_usda_client

    client = get_usda_client()
    results = await client.search(query, page_size=limit)
    return USDASearchResponse(results=[USDAFoodResult(**row) for row in results])
