"""Daily-summary and calorie-rollup read paths.

Composes the targets and entries repositories to build a single-day
:class:`DailySummaryResponse` (target / consumed / remaining macros + the
day's entries), and provides :func:`daily_calorie_totals` for multi-day
calorie roll-ups used by the weight/calorie charts. Read-only; never opens
a transaction.
"""

from __future__ import annotations

from datetime import date as DateValue
from typing import Literal

from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.log_ids import daily_log_id
from pulse_server.macro_aggregates import remaining_macros, sum_food_entry_macros
from pulse_server.models import DailySummaryResponse, FoodEntryResponse
from pulse_server.models.adapters import macro_targets_from_row
from pulse_server.models.daily import CaloriesDailyRow
from pulse_server.repositories.entries import EntriesRepository
from pulse_server.repositories.targets import TargetsRepository
from pulse_server.services.date_utils import validate_range


async def build_daily_summary(
    session: AsyncSession,
    user_key: str,
    summary_date: DateValue,
    missing_target: Literal["raise", "null"] = "raise",
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
    - missing_target ("raise" | "null"): Behavior when no target profile
      exists. ``"raise"`` (default, used by the REST ``/summary`` endpoint)
      raises 404; ``"null"`` (used by the MCP ``get_day`` tool) returns the
      consumed totals and entries with ``target``/``remaining`` set to ``None``.

    **Outputs:**
    - DailySummaryResponse: Computed summary including target, consumed,
      remaining, and the day's entries.

    **Exceptions:**
    - fastapi.HTTPException: Raised with 404 when no target profile exists
      and ``missing_target == "raise"``.
    - sqlalchemy.exc.SQLAlchemyError: Raised when repository queries fail.
    """
    targets_repo = TargetsRepository(session)
    entries_repo = EntriesRepository(session)

    target_row = await targets_repo.get_target_profile(user_key)
    if target_row is None and missing_target == "raise":
        raise HTTPException(status_code=404, detail=f"No target profile for user {user_key}")

    summary_daily_log_id = daily_log_id(user_key, summary_date)
    entry_rows = await entries_repo.list_entries_by_daily_log_id(summary_daily_log_id)
    entries = [FoodEntryResponse(**row) for row in entry_rows]
    consumed = sum_food_entry_macros(entries)

    if target_row is None:
        return DailySummaryResponse(
            date=summary_date,
            target=None,
            consumed=consumed,
            remaining=None,
            entries=entries,
        )

    target = macro_targets_from_row(target_row)
    return DailySummaryResponse(
        date=summary_date,
        target=target,
        consumed=consumed,
        remaining=remaining_macros(target, consumed),
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

    **Raises:**
    - ValueError: Raised when the range is invalid (see
      :func:`validate_range`).
    - sqlalchemy.exc.SQLAlchemyError: Raised when the query fails.
    """
    validate_range(from_date, to_date)
    entries_repo = EntriesRepository(session)
    rows = await entries_repo.calorie_totals_by_day(
        user_key=user_key, from_date=from_date, to_date=to_date
    )
    return [
        CaloriesDailyRow(log_date=row["log_date"], calories=int(row["calories"]))
        for row in rows
    ]
