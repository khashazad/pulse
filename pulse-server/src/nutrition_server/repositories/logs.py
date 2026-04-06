from __future__ import annotations

from datetime import date as DateValue
from typing import Any

from sqlalchemy import Integer, cast, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.repositories.tables import daily_logs, food_entries


class LogsRepository:
    # Summary: Initializes a logs repository bound to an active SQLAlchemy session.
    # Parameters:
    # - session (AsyncSession): SQLAlchemy async session used for all repository operations.
    # Returns:
    # - None: Stores the session for subsequent method calls.
    # Raises/Throws:
    # - None: Initialization only stores references and performs no I/O.
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    # Summary: Lists daily aggregate totals and entry counts for a user across a date range.
    # Parameters:
    # - user_key (str): User identifier whose logs are queried.
    # - from_date (DateValue): Inclusive start date filter.
    # - to_date (DateValue): Inclusive end date filter.
    # Returns:
    # - list[dict[str, Any]]: Date-ordered aggregate rows with macro totals and entry counts.
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    async def list_logs(self, user_key: str, from_date: DateValue, to_date: DateValue) -> list[dict[str, Any]]:
        join_stmt = daily_logs.outerjoin(food_entries, food_entries.c.daily_log_id == daily_logs.c.id)
        stmt = (
            select(
                daily_logs.c.log_date.label("log_date"),
                cast(func.coalesce(func.sum(food_entries.c.calories), 0), Integer).label("total_calories"),
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
