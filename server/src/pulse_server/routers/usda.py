"""Thin proxy router over the USDA FoodData Central search API.

Exposes ``GET /usda/search`` which forwards the user's query to the configured
:class:`USDAClient` and returns normalized macro-mapped results. Used by the
iOS client only when local food memory misses.

Every forwarded request spends the server's shared USDA API key and ties up a
worker on a slow outbound call, so the route caps query length and applies a
per-user sliding-window rate limit to bound abuse from any single (valid or
stolen) session.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, Request

from pulse_server.auth import require_session
from pulse_server.models import USDAFoodResult, USDASearchResponse
from pulse_server.services.rate_limit import SlidingWindowRateLimiter
from pulse_server.usda_provider import USDAClientDep

router = APIRouter(dependencies=[Depends(require_session)])

# Upper bound on the search phrase; USDA queries are short food names, so a long
# string is almost certainly abuse or a bug rather than a legitimate search.
USDA_QUERY_MAX_LENGTH = 100

# Per-user throttle: bounds upstream-quota burn and outbound-request concurrency
# from a single session without blocking normal interactive search.
USDA_RATE_LIMIT_MAX_REQUESTS = 30
USDA_RATE_LIMIT_WINDOW_SECONDS = 60.0
_usda_rate_limiter = SlidingWindowRateLimiter(
    max_requests=USDA_RATE_LIMIT_MAX_REQUESTS,
    window_seconds=USDA_RATE_LIMIT_WINDOW_SECONDS,
)


@router.get("/usda/search", response_model=USDASearchResponse)
async def search_usda(
    request: Request,
    client: USDAClientDep,
    query: str = Query(..., alias="q", min_length=1, max_length=USDA_QUERY_MAX_LENGTH),
    limit: int = Query(default=5, ge=1, le=25),
) -> USDASearchResponse:
    """Proxy a search to USDA FoodData Central and return normalized diet records.

    **Inputs:**
    - request (Request): Active request providing the authenticated ``user_key``
      used as the rate-limit key.
    - client (USDAClient): Live USDA client supplied via FastAPI dependency
      injection (see :data:`pulse_server.usda_provider.USDAClientDep`).
    - query (str): Search phrase (query alias ``q``); 1..``USDA_QUERY_MAX_LENGTH`` chars.
    - limit (int): Maximum number of food matches to return, in ``[1, 25]``.

    **Outputs:**
    - USDASearchResponse: Normalized food search results with diet macros mapped.

    **Raises:**
    - HTTPException(429): Raised when the user exceeds the per-user search rate limit.
    - RuntimeError: Raised if the USDA client is not initialized.
    - httpx.HTTPError: Raised when the upstream USDA request fails.
    """
    user_key = request.state.user_key
    if not _usda_rate_limiter.allow(user_key):
        raise HTTPException(
            status_code=429,
            detail="USDA search rate limit exceeded; slow down and try again shortly.",
        )

    results = await client.search(query, page_size=limit)
    return USDASearchResponse(results=[USDAFoodResult(**row) for row in results])
