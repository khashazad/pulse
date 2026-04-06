from __future__ import annotations

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.auth import require_api_key
from nutrition_server.config import get_settings
from nutrition_server.db import get_session_dependency
from nutrition_server.models import MatchHistoryEntry, MatchHistoryResponse
from nutrition_server.repositories.history import HistoryRepository

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
# - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
@router.get("/match-history", response_model=MatchHistoryResponse)
async def search_match_history(
    query: str = Query(..., alias="q", min_length=1),
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> MatchHistoryResponse:
    effective_user_key = user_key or settings.default_user_key
    repository = HistoryRepository(session)
    rows = await repository.search_matches(effective_user_key, query)

    return MatchHistoryResponse(matches=[MatchHistoryEntry(**row) for row in rows])
