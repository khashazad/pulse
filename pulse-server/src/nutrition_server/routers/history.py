from __future__ import annotations

from fastapi import APIRouter, Depends, Query

from nutrition_server.auth import require_api_key
from nutrition_server.config import get_settings
from nutrition_server.db import get_conn
from nutrition_server.models import MatchHistoryEntry, MatchHistoryResponse

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_api_key)])


# Summary: Searches past confirmed food phrase matches for disambiguation hints.
# Parameters:
# - query (str): Raw phrase fragment matched via case-insensitive substring.
# - user_key (str | None): Optional user identifier override.
# Returns:
# - MatchHistoryResponse: Ranked historical phrase-to-food matches.
# Raises/Throws:
# - RuntimeError: Raised when the database pool is not initialized.
# - psycopg.Error: Raised when SQL execution fails.
@router.get("/match-history", response_model=MatchHistoryResponse)
async def search_match_history(
    query: str = Query(..., alias="q", min_length=1),
    user_key: str | None = Query(default=None),
) -> MatchHistoryResponse:
    effective_user_key = user_key or settings.default_user_key
    async with get_conn() as conn:
        cur = await conn.execute(
            """SELECT raw_phrase, quantity_text, usda_fdc_id, usda_description,
                      times_confirmed, last_confirmed_at
               FROM food_match_history
               WHERE user_key = %s AND raw_phrase ILIKE %s
               ORDER BY times_confirmed DESC, last_confirmed_at DESC
               LIMIT 10""",
            (effective_user_key, f"%{query}%"),
        )
        rows = await cur.fetchall()

    return MatchHistoryResponse(matches=[MatchHistoryEntry(**row) for row in rows])
