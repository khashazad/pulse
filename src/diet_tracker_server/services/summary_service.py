"""Daily-summary and calorie-rollup read paths.

Composes the targets and entries repositories to build a single-day
:class:`DailySummaryResponse` (target / consumed / remaining macros + the
day's entries), and provides :func:`daily_calorie_totals` for multi-day
calorie roll-ups used by the weight/calorie charts. Read-only; never opens
a transaction.
"""

from __future__ import annotations

from datetime import date as DateValue

from fastapi import HTTPException
from sqlalchemy import func as sa_func
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.macro_aggregates import sum_food_entry_macros
from diet_tracker_server.models import DailySummaryResponse, FoodEntryResponse, MacroTargets, MacroTotals
from diet_tracker_server.models.weight import CaloriesDailyRow
from diet_tracker_server.repositories.entries import EntriesRepository
from diet_tracker_server.repositories.tables import daily_logs, food_entries
from diet_tracker_server.repositories.targets import TargetsRepository
from diet_tracker_server.services.log_ids import daily_log_id


async def build_daily_summary(
    session: AsyncSession,
    user_key: str,
    summary_date: DateValue,
) -> DailySummaryResponse:
    """Build a daily summary payload from persisted target and entry data.

    Loads the user's macro target profile, the day's entries (via the
    deterministic ``daily_log_id``), sums the consumed macros, and returns
    target / consumed / remaining triplets alongside the entry list.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session for repository reads.
    - user_key (str): User identifier whose summary is requested.
    - summary_date (DateValue): Date for which target/consumed/remaining
      totals are computed.

    **Outputs:**
    - DailySummaryResponse: Computed summary including target, consumed,
      remaining, and the day's entries.

    **Exceptions:**
    - fastapi.HTTPException: Raised with 404 when no target profile exists
      for the user.
    - sqlalchemy.exc.SQLAlchemyError: Raised when repository queries fail.
    """
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
    consumed = sum_food_entry_macros(entries)
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


async def daily_calorie_totals(
    session: AsyncSession,
    user_key: str,
    from_date: DateValue,
    to_date: DateValue,
) -> list[CaloriesDailyRow]:
    """Sum food-entry calories per day within an inclusive date range.

    Joins ``food_entries`` to ``daily_logs`` so days with zero entries are
    omitted (callers fill gaps as needed).

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session.
    - user_key (str): Owning user's scoping key.
    - from_date (DateValue): Inclusive lower bound on ``log_date``.
    - to_date (DateValue): Inclusive upper bound on ``log_date``.

    **Outputs:**
    - list[CaloriesDailyRow]: One row per day with at least one entry,
      ordered by ``log_date`` ascending.

    **Exceptions:**
    - sqlalchemy.exc.SQLAlchemyError: Raised when the query fails.
    """
    stmt = (
        select(
            daily_logs.c.log_date.label("log_date"),
            sa_func.coalesce(sa_func.sum(food_entries.c.calories), 0).label("calories"),
        )
        .select_from(food_entries.join(daily_logs, daily_logs.c.id == food_entries.c.daily_log_id))
        .where(daily_logs.c.user_key == user_key)
        .where(daily_logs.c.log_date >= from_date)
        .where(daily_logs.c.log_date <= to_date)
        .group_by(daily_logs.c.log_date)
        .order_by(daily_logs.c.log_date.asc())
    )
    result = await session.execute(stmt)
    return [
        CaloriesDailyRow(log_date=row["log_date"], calories=int(row["calories"]))
        for row in result.mappings()
    ]
