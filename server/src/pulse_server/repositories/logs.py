"""Daily-log aggregation persistence layer.

Provides :class:`LogsRepository`, which owns the read-side SQL that summarizes
per-day macro totals and entry counts by joining ``daily_logs`` to
``food_entries``. Used by the logs service to power calendar / history
endpoints.

Sits between the logs service and the underlying Postgres table definitions
(``repositories/tables.py``); writes to ``daily_logs`` live in
``EntriesRepository.ensure_daily_log`` instead.
"""

from __future__ import annotations

from datetime import date as DateValue
from typing import Any

from sqlalchemy import Integer, cast, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.repositories.tables import daily_logs, food_entries


class LogsRepository:
    def __init__(self, session: AsyncSession) -> None:
        """Bind the repository to an open async session.

        **Inputs:**
        - session (AsyncSession): SQLAlchemy async session used for all queries
          issued by this repository instance.
        """
        self._session = session

    async def list_logs(
        self, user_key: str, from_date: DateValue, to_date: DateValue
    ) -> list[dict[str, Any]]:
        """List per-day macro totals and entry counts for a user across a date range.

        Outer-joins ``daily_logs`` to ``food_entries`` so days with zero
        entries still appear with zero totals. Results are ordered most-recent
        first.

        **Inputs:**
        - user_key (str): User identifier whose logs are queried.
        - from_date (DateValue): Inclusive start date filter.
        - to_date (DateValue): Inclusive end date filter.

        **Outputs:**
        - list[dict[str, Any]]: Date-ordered aggregate rows with macro totals
          and entry counts.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        # Confirmed-only filter lives in the JOIN condition (not WHERE) so days
        # with zero confirmed entries — including pending-only future days —
        # still appear with zero totals instead of dropping out of the range.
        join_stmt = daily_logs.outerjoin(
            food_entries,
            (food_entries.c.daily_log_id == daily_logs.c.id) & (food_entries.c.confirmed.is_(True)),
        )
        stmt = (
            select(
                daily_logs.c.log_date.label("log_date"),
                cast(func.coalesce(func.sum(food_entries.c.calories), 0), Integer).label(
                    "total_calories"
                ),
                func.coalesce(func.sum(food_entries.c.protein_g), 0).label("total_protein_g"),
                func.coalesce(func.sum(food_entries.c.carbs_g), 0).label("total_carbs_g"),
                func.coalesce(func.sum(food_entries.c.fat_g), 0).label("total_fat_g"),
                cast(func.count(food_entries.c.id), Integer).label("entry_count"),
            )
            .select_from(join_stmt)
            .where(daily_logs.c.user_key == user_key)
            .where(daily_logs.c.log_date >= from_date)
            .where(daily_logs.c.log_date <= to_date)
            .group_by(daily_logs.c.log_date)
            .order_by(daily_logs.c.log_date.desc())
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]
