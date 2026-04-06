from __future__ import annotations

import uuid
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query

from nutrition_server.auth import require_api_key
from nutrition_server.config import get_settings
from nutrition_server.db import get_conn
from nutrition_server.models import (
    EntriesCreateRequest,
    EntriesCreateResponse,
    EntriesListResponse,
    FoodEntryResponse,
    MacroTotals,
)

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_api_key)])
TZ = ZoneInfo(settings.timezone)


# Summary: Derives a stable UUID for a user's daily log date.
# Parameters:
# - user_key (str): Unique user identifier owning the nutrition log.
# - log_date (datetime.date): Target log date to derive the deterministic UUID for.
# Returns:
# - str: UUID5 string derived from user key and date.
# Raises/Throws:
# - None: UUID derivation is deterministic and non-throwing for valid inputs.
def _daily_log_id(user_key: str, log_date: DateValue) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{user_key}:{log_date.isoformat()}"))


# Summary: Aggregates a list of food entries into total macro values.
# Parameters:
# - entries (list[FoodEntryResponse]): Food entry records to total.
# Returns:
# - MacroTotals: Summed calories/protein/carbs/fat rounded to one decimal place.
# Raises/Throws:
# - None: Numeric aggregation is deterministic for valid entry payloads.
def _sum_totals(entries: list[FoodEntryResponse]) -> MacroTotals:
    return MacroTotals(
        calories=sum(entry.calories for entry in entries),
        protein_g=round(sum(entry.protein_g for entry in entries), 1),
        carbs_g=round(sum(entry.carbs_g for entry in entries), 1),
        fat_g=round(sum(entry.fat_g for entry in entries), 1),
    )


# Summary: Creates one or more food entries and updates alias/history tables atomically.
# Parameters:
# - body (EntriesCreateRequest): Requested entries plus optional user key override.
# Returns:
# - EntriesCreateResponse: Persisted entries and the day's aggregate macro totals.
# Raises/Throws:
# - RuntimeError: Raised when the database pool is not initialized.
# - psycopg.Error: Raised when SQL execution fails.
@router.post("/entries", status_code=201, response_model=EntriesCreateResponse)
async def create_entries(body: EntriesCreateRequest) -> EntriesCreateResponse:
    user_key = body.user_key or settings.default_user_key
    now = DateTimeValue.now(tz=TZ)

    async with get_conn() as conn:
        created: list[FoodEntryResponse] = []
        for item in body.items:
            log_date = item.date or now.date()
            consumed_at = item.consumed_at or now
            daily_log_id = _daily_log_id(user_key, log_date)
            entry_group_id = str(uuid.uuid4())

            await conn.execute(
                """INSERT INTO daily_logs (id, user_key, log_date)
                   VALUES (%s, %s, %s)
                   ON CONFLICT (user_key, log_date) DO NOTHING""",
                (daily_log_id, user_key, log_date),
            )

            entry_id = str(uuid.uuid4())
            cur = await conn.execute(
                """INSERT INTO food_entries (
                       id, daily_log_id, user_key, entry_group_id,
                       display_name, quantity_text,
                       normalized_quantity_value, normalized_quantity_unit,
                       usda_fdc_id, usda_description,
                       calories, protein_g, carbs_g, fat_g, consumed_at
                   ) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                   RETURNING *""",
                (
                    entry_id,
                    daily_log_id,
                    user_key,
                    entry_group_id,
                    item.display_name,
                    item.quantity_text,
                    item.normalized_quantity_value,
                    item.normalized_quantity_unit,
                    item.usda_fdc_id,
                    item.usda_description,
                    item.calories,
                    item.protein_g,
                    item.carbs_g,
                    item.fat_g,
                    consumed_at,
                ),
            )
            created.append(FoodEntryResponse(**(await cur.fetchone())))

            await conn.execute(
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
                       confidence_score = food_aliases.confidence_score + 1,
                       last_confirmed_at = EXCLUDED.last_confirmed_at,
                       updated_at = EXCLUDED.updated_at""",
                (
                    user_key,
                    item.display_name,
                    item.display_name,
                    item.normalized_quantity_value,
                    item.normalized_quantity_unit,
                    item.usda_fdc_id,
                    item.usda_description,
                    consumed_at,
                    consumed_at,
                ),
            )

            await conn.execute(
                """INSERT INTO food_match_history (
                       user_key, raw_phrase, quantity_text,
                       usda_fdc_id, usda_description,
                       times_confirmed, last_confirmed_at, updated_at
                   ) VALUES (%s,%s,%s,%s,%s,1,%s,%s)
                   ON CONFLICT ON CONSTRAINT idx_food_match_history_match_key
                   DO UPDATE SET
                       times_confirmed = food_match_history.times_confirmed + 1,
                       last_confirmed_at = EXCLUDED.last_confirmed_at,
                       updated_at = EXCLUDED.updated_at""",
                (
                    user_key,
                    item.display_name,
                    item.quantity_text,
                    item.usda_fdc_id,
                    item.usda_description,
                    consumed_at,
                    consumed_at,
                ),
            )

        today_log_id = _daily_log_id(user_key, now.date())
        cur = await conn.execute(
            "SELECT * FROM food_entries WHERE daily_log_id = %s ORDER BY consumed_at",
            (today_log_id,),
        )
        all_entries = [FoodEntryResponse(**row) for row in await cur.fetchall()]

    return EntriesCreateResponse(entries=created, daily_totals=_sum_totals(all_entries))


# Summary: Lists all entries for a user's requested log date.
# Parameters:
# - log_date (datetime.date): Date filter for selecting entries.
# - user_key (str | None): Optional user identifier override.
# Returns:
# - EntriesListResponse: Date-scoped entries with aggregate macros.
# Raises/Throws:
# - RuntimeError: Raised when the database pool is not initialized.
# - psycopg.Error: Raised when SQL execution fails.
@router.get("/entries", response_model=EntriesListResponse)
async def list_entries(
    log_date: DateValue = Query(..., alias="date"),
    user_key: str | None = Query(default=None),
) -> EntriesListResponse:
    effective_user_key = user_key or settings.default_user_key
    daily_log_id = _daily_log_id(effective_user_key, log_date)
    async with get_conn() as conn:
        cur = await conn.execute(
            "SELECT * FROM food_entries WHERE daily_log_id = %s ORDER BY consumed_at",
            (daily_log_id,),
        )
        rows = await cur.fetchall()

    entries = [FoodEntryResponse(**row) for row in rows]
    return EntriesListResponse(date=log_date, entries=entries, totals=_sum_totals(entries))


# Summary: Deletes a single food entry by ID.
# Parameters:
# - entry_id (str): UUID string identifying the food entry row.
# Returns:
# - None: Endpoint returns HTTP 204 when deletion succeeds.
# Raises/Throws:
# - fastapi.HTTPException: Raised with 404 when the entry does not exist.
# - RuntimeError: Raised when the database pool is not initialized.
# - psycopg.Error: Raised when SQL execution fails.
@router.delete("/entries/{entry_id}", status_code=204)
async def delete_entry(entry_id: str) -> None:
    async with get_conn() as conn:
        result = await conn.execute("DELETE FROM food_entries WHERE id = %s", (entry_id,))
        if result.rowcount == 0:
            raise HTTPException(status_code=404, detail="Entry not found")
