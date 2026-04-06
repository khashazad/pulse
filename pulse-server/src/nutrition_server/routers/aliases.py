from __future__ import annotations

from datetime import datetime as DateTimeValue
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Query

from nutrition_server.auth import require_api_key
from nutrition_server.config import get_settings
from nutrition_server.db import get_conn
from nutrition_server.models import AliasCreate, AliasListResponse, AliasResponse

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
# - psycopg.Error: Raised when SQL execution fails.
@router.get("/aliases", response_model=AliasListResponse)
async def search_aliases(
    query: str = Query(..., alias="q", min_length=1),
    user_key: str | None = Query(default=None),
) -> AliasListResponse:
    effective_user_key = user_key or settings.default_user_key
    async with get_conn() as conn:
        cur = await conn.execute(
            """SELECT * FROM food_aliases
               WHERE user_key = %s AND alias_text ILIKE %s
               ORDER BY confidence_score DESC, last_confirmed_at DESC
               LIMIT 10""",
            (effective_user_key, f"%{query}%"),
        )
        rows = await cur.fetchall()

    return AliasListResponse(aliases=[AliasResponse(**row) for row in rows])


# Summary: Creates or updates an alias preference for a food phrase.
# Parameters:
# - body (AliasCreate): Alias payload describing preferred USDA mapping and defaults.
# Returns:
# - AliasResponse: Persisted alias row after insert or upsert update.
# Raises/Throws:
# - RuntimeError: Raised when the database pool is not initialized.
# - psycopg.Error: Raised when SQL execution fails.
@router.post("/aliases", status_code=201, response_model=AliasResponse)
async def create_alias(body: AliasCreate) -> AliasResponse:
    effective_user_key = body.user_key or settings.default_user_key
    now = DateTimeValue.now(tz=TZ)
    async with get_conn() as conn:
        cur = await conn.execute(
            """INSERT INTO food_aliases (
                   user_key, alias_text, preferred_label,
                   default_quantity_value, default_quantity_unit,
                   preferred_usda_fdc_id, preferred_usda_description,
                   confidence_score, last_confirmed_at, updated_at
               ) VALUES (%s,%s,%s,%s,%s,%s,%s,1.0,%s,%s)
               ON CONFLICT (user_key, alias_text)
               DO UPDATE SET
                   preferred_label = EXCLUDED.preferred_label,
                   default_quantity_value = EXCLUDED.default_quantity_value,
                   default_quantity_unit = EXCLUDED.default_quantity_unit,
                   preferred_usda_fdc_id = EXCLUDED.preferred_usda_fdc_id,
                   preferred_usda_description = EXCLUDED.preferred_usda_description,
                   last_confirmed_at = EXCLUDED.last_confirmed_at,
                   updated_at = EXCLUDED.updated_at
               RETURNING *""",
            (
                effective_user_key,
                body.alias_text,
                body.preferred_label,
                body.default_quantity_value,
                body.default_quantity_unit,
                body.preferred_usda_fdc_id,
                body.preferred_usda_description,
                now,
                now,
            ),
        )
        row = await cur.fetchone()

    return AliasResponse(**row)
