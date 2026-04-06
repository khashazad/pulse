from __future__ import annotations

from datetime import date as DateValue

from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.models import DailySummaryResponse, FoodEntryResponse, MacroTargets, MacroTotals
from nutrition_server.repositories.entries import EntriesRepository
from nutrition_server.repositories.targets import TargetsRepository
from nutrition_server.services.log_ids import daily_log_id


# Summary: Builds a daily summary payload from persisted target and entry data.
# Parameters:
# - session (AsyncSession): Active SQLAlchemy session for repository reads.
# - user_key (str): User identifier whose summary is requested.
# - summary_date (DateValue): Date for which target/consumed/remaining totals are computed.
# Returns:
# - DailySummaryResponse: Computed summary including target, consumed, remaining, and entries.
# Raises/Throws:
# - fastapi.HTTPException: Raised with 404 when no target profile exists for the user.
# - sqlalchemy.exc.SQLAlchemyError: Raised when repository queries fail.
async def build_daily_summary(
    session: AsyncSession,
    user_key: str,
    summary_date: DateValue,
) -> DailySummaryResponse:
    targets_repo = TargetsRepository(session)
    entries_repo = EntriesRepository(session)

    target_row = await targets_repo.get_target_profile(user_key)
    if target_row is None:
        raise HTTPException(status_code=404, detail=f"No target profile for user {user_key}")

    summary_daily_log_id = daily_log_id(user_key, summary_date)
    entry_rows = await entries_repo.list_entries_by_daily_log_id(summary_daily_log_id)
    entries = [FoodEntryResponse(**row) for row in entry_rows]

    target = MacroTargets(
        calories=int(target_row["calories_target"]),
        protein_g=float(target_row["protein_g_target"]),
        carbs_g=float(target_row["carbs_g_target"]),
        fat_g=float(target_row["fat_g_target"]),
    )
    consumed = MacroTotals(
        calories=sum(entry.calories for entry in entries),
        protein_g=round(sum(entry.protein_g for entry in entries), 1),
        carbs_g=round(sum(entry.carbs_g for entry in entries), 1),
        fat_g=round(sum(entry.fat_g for entry in entries), 1),
    )
    remaining = MacroTotals(
        calories=target.calories - consumed.calories,
        protein_g=round(target.protein_g - consumed.protein_g, 1),
        carbs_g=round(target.carbs_g - consumed.carbs_g, 1),
        fat_g=round(target.fat_g - consumed.fat_g, 1),
    )

    return DailySummaryResponse(
        date=summary_date,
        target=target,
        consumed=consumed,
        remaining=remaining,
        entries=entries,
    )
