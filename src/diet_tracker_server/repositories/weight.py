"""Weight-entry persistence layer.

Provides :class:`WeightRepository`, which encapsulates all SQL access to the
``weight_entries`` table: upsert by ``(user_key, log_date)``, range queries,
single-day lookup, and deletion. Built on SQLAlchemy Core (no ORM) and exposes
an async API backed by an :class:`AsyncSession`.

Sits between the weight service (``services/weight_service.py``) and the
underlying Postgres table definition (``repositories/tables.py``); it is the
only module in the codebase allowed to issue weight-table SQL.
"""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from decimal import Decimal
from typing import Any

from sqlalchemy import delete as sa_delete
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.repositories.tables import weight_entries


class WeightRepository:
    """Async repository for the ``weight_entries`` table.

    Owns every SQL statement that touches ``weight_entries`` and returns plain
    ``dict`` rows so callers stay decoupled from SQLAlchemy result objects.
    """

    def __init__(self, session: AsyncSession) -> None:
        """Bind the repository to an open async session.

        **Inputs:**
        - session (AsyncSession): SQLAlchemy async session used for all queries
          issued by this repository instance.
        """
        self._session = session

    async def upsert(
        self,
        user_key: str,
        log_date: DateValue,
        weight_lb: Decimal,
        source_unit: str,
        updated_at: DateTimeValue,
    ) -> dict[str, Any]:
        """Insert or update the weight entry for ``(user_key, log_date)``.

        Uses Postgres ``ON CONFLICT`` against the ``(user_key, log_date)`` unique
        index so the call is idempotent per day.

        **Inputs:**
        - user_key (str): Scoping key for the owning user.
        - log_date (date): Calendar date the weight reading applies to.
        - weight_lb (Decimal): Weight in pounds (normalized by the caller).
        - source_unit (str): Unit the user originally entered (``"lb"`` or ``"kg"``).
        - updated_at (datetime): UTC timestamp recorded as the row's mtime.

        **Outputs:**
        - dict[str, Any]: The full inserted/updated row as a column→value mapping.
        """
        stmt = pg_insert(weight_entries).values(
            user_key=user_key,
            log_date=log_date,
            weight_lb=weight_lb,
            source_unit=source_unit,
            updated_at=updated_at,
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=[weight_entries.c.user_key, weight_entries.c.log_date],
            set_={
                "weight_lb": stmt.excluded.weight_lb,
                "source_unit": stmt.excluded.source_unit,
                "updated_at": updated_at,
            },
        ).returning(*weight_entries.c)
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        assert row is not None
        return dict(row)

    async def list_range(
        self,
        user_key: str,
        from_date: DateValue,
        to_date: DateValue,
    ) -> list[dict[str, Any]]:
        """Return all weight entries for ``user_key`` within an inclusive date range.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - from_date (date): Inclusive lower bound on ``log_date``.
        - to_date (date): Inclusive upper bound on ``log_date``.

        **Outputs:**
        - list[dict[str, Any]]: Rows ordered by ``log_date`` ascending; empty when
          no entries exist in the range.
        """
        stmt = (
            select(*weight_entries.c)
            .where(weight_entries.c.user_key == user_key)
            .where(weight_entries.c.log_date >= from_date)
            .where(weight_entries.c.log_date <= to_date)
            .order_by(weight_entries.c.log_date.asc())
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings()]

    async def get_by_date(
        self,
        user_key: str,
        log_date: DateValue,
    ) -> dict[str, Any] | None:
        """Fetch the weight entry for a specific user and date, if one exists.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - log_date (date): Calendar date to look up.

        **Outputs:**
        - dict[str, Any] | None: The row as a column→value mapping, or ``None``
          when no entry is recorded for that day.
        """
        stmt = (
            select(*weight_entries.c)
            .where(weight_entries.c.user_key == user_key)
            .where(weight_entries.c.log_date == log_date)
            .limit(1)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def delete(
        self,
        user_key: str,
        log_date: DateValue,
    ) -> bool:
        """Remove the weight entry for ``(user_key, log_date)``.

        **Inputs:**
        - user_key (str): Owning user's scoping key.
        - log_date (date): Calendar date of the entry to delete.

        **Outputs:**
        - bool: ``True`` when a row was removed, ``False`` when no matching row
          existed.
        """
        stmt = (
            sa_delete(weight_entries)
            .where(weight_entries.c.user_key == user_key)
            .where(weight_entries.c.log_date == log_date)
        )
        result = await self._session.execute(stmt)
        return result.rowcount > 0
