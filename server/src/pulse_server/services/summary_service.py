"""Daily-summary and calorie-rollup read paths.

Composes the targets and entries repositories to build a single-day
:class:`DailySummaryResponse` (target / consumed / remaining macros + the
day's entries), and provides :func:`daily_calorie_totals` for multi-day
calorie roll-ups used by the weight/calorie charts. Read-only; never opens
a transaction.
"""

from __future__ import annotations

from datetime import date as DateValue
from datetime import timedelta
from typing import Literal

from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.log_ids import daily_log_id
from pulse_server.macro_aggregates import (
    confirmed_entries,
    remaining_macros,
    sum_food_entry_macros,
)
from pulse_server.models import DailySummaryResponse, FoodEntryResponse, MacroTargets
from pulse_server.models.adapters import macro_targets_from_row
from pulse_server.models.daily import CaloriesDailyRow
from pulse_server.repositories.entries import EntriesRepository
from pulse_server.repositories.targets import TargetsRepository
from pulse_server.services.date_utils import validate_range


def _assemble_daily_summary(
    summary_date: DateValue,
    target: MacroTargets | None,
    entries: list[FoodEntryResponse],
) -> DailySummaryResponse:
    """Build a ``DailySummaryResponse`` from a resolved target and entry list.

    Pure assembly step shared by :func:`build_daily_summary` and
    :func:`build_range_summaries`: sums the entries and computes remaining
    macros (``None`` when no target profile applies).

    **Inputs:**
    - summary_date (DateValue): The day the summary describes.
    - target (MacroTargets | None): Resolved target profile, or ``None``.
    - entries (list[FoodEntryResponse]): The day's food entries.

    **Outputs:**
    - DailySummaryResponse: Target / consumed / remaining triplet plus entries.

    The returned ``entries`` list keeps every row (pending included, each
    carrying its ``confirmed`` flag) so clients can render and confirm them, but
    ``consumed`` sums only confirmed entries so unconfirmed future portions never
    inflate the day's totals.
    """
    consumed = sum_food_entry_macros(confirmed_entries(entries))
    return DailySummaryResponse(
        date=summary_date,
        target=target,
        consumed=consumed,
        remaining=remaining_macros(target, consumed) if target is not None else None,
        entries=entries,
    )


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
    target = macro_targets_from_row(target_row) if target_row is not None else None
    return _assemble_daily_summary(summary_date, target, entries)


async def build_range_summaries(
    session: AsyncSession,
    user_key: str,
    from_date: DateValue,
    to_date: DateValue,
) -> list[DailySummaryResponse]:
    """Build one daily summary per day across an inclusive date range.

    Mirrors :func:`build_daily_summary` per day, but fetches the (global,
    request-stable) target profile once instead of re-querying it for every
    day, then loops the per-day entry reads. A missing profile yields ``None``
    targets on every day (the ``missing_target="null"`` behavior) rather than
    raising.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session for repository reads.
    - user_key (str): User identifier whose summaries are requested.
    - from_date (DateValue): Inclusive lower bound on the range.
    - to_date (DateValue): Inclusive upper bound on the range.

    **Outputs:**
    - list[DailySummaryResponse]: One summary per calendar day, ascending by
      date. Unlogged days appear with zero consumed totals and no entries.

    **Raises:**
    - ValueError: Raised when the range is invalid (see
      :func:`validate_range`).
    - sqlalchemy.exc.SQLAlchemyError: Raised when repository queries fail.
    """
    validate_range(from_date, to_date)
    targets_repo = TargetsRepository(session)
    entries_repo = EntriesRepository(session)

    target_row = await targets_repo.get_target_profile(user_key)
    target = macro_targets_from_row(target_row) if target_row is not None else None

    summaries: list[DailySummaryResponse] = []
    current = from_date
    while current <= to_date:
        entry_rows = await entries_repo.list_entries_by_daily_log_id(
            daily_log_id(user_key, current)
        )
        entries = [FoodEntryResponse(**row) for row in entry_rows]
        summaries.append(_assemble_daily_summary(current, target, entries))
        current += timedelta(days=1)
    return summaries


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
        CaloriesDailyRow(log_date=row["log_date"], calories=int(row["calories"])) for row in rows
    ]
