from __future__ import annotations

from datetime import datetime as DateTimeValue
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Query, Response, status
from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.auth import require_api_key
from nutrition_server.config import get_settings
from nutrition_server.db import get_session_dependency, transaction
from nutrition_server.models import AliasCreate, AliasListResponse, AliasResponse
from nutrition_server.repositories.aliases import AliasesRepository

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_api_key)])
TZ = ZoneInfo(settings.timezone)


# Summary: Searches alias mappings by phrase for a user.
# Parameters:
# - query (str): Alias search phrase matched via case-insensitive substring.
# - user_key (str | None): Optional user identifier override.
# Returns:
# - AliasListResponse: Top matching aliases sorted by confidence and recency.
# Raises/Throws:
# - RuntimeError: Raised when the database pool is not initialized.
# - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
@router.get("/aliases", response_model=AliasListResponse)
async def search_aliases(
    query: str = Query(..., alias="q", min_length=1),
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> AliasListResponse:
    effective_user_key = user_key or settings.default_user_key
    repository = AliasesRepository(session)
    rows = await repository.search_aliases(effective_user_key, query)

    return AliasListResponse(aliases=[AliasResponse(**row) for row in rows])


# Summary: Creates or updates an alias preference for a food phrase.
# Parameters:
# - body (AliasCreate): Alias payload describing preferred USDA mapping and defaults.
# - response (fastapi.Response): Response object used to emit 201 on insert and 200 on update.
# - session (AsyncSession): Request-scoped SQLAlchemy session used for persistence.
# Returns:
# - AliasResponse: Persisted alias row after insert or upsert update.
# Raises/Throws:
# - RuntimeError: Raised when the database pool is not initialized.
# - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
@router.post("/aliases", response_model=AliasResponse)
async def create_alias(
    body: AliasCreate,
    response: Response,
    session: AsyncSession = Depends(get_session_dependency),
) -> AliasResponse:
    effective_user_key = body.user_key or settings.default_user_key
    now = DateTimeValue.now(tz=TZ)
    repository = AliasesRepository(session)
    async with transaction(session):
        row, created = await repository.create_or_update_alias_with_state(
            user_key=effective_user_key,
            alias_text=body.alias_text,
            preferred_label=body.preferred_label,
            preferred_usda_fdc_id=body.preferred_usda_fdc_id,
            preferred_usda_description=body.preferred_usda_description,
            default_quantity_value=body.default_quantity_value,
            default_quantity_unit=body.default_quantity_unit,
            confirmed_at=now,
            updated_at=now,
            increment_confidence=False,
        )

    response.status_code = status.HTTP_201_CREATED if created else status.HTTP_200_OK
    return AliasResponse(**row)
