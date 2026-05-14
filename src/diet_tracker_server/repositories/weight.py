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
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def upsert(
        self,
        user_key: str,
        log_date: DateValue,
        weight_lb: Decimal,
        source_unit: str,
        updated_at: DateTimeValue,
    ) -> dict[str, Any]:
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
        stmt = (
            sa_delete(weight_entries)
            .where(weight_entries.c.user_key == user_key)
            .where(weight_entries.c.log_date == log_date)
        )
        result = await self._session.execute(stmt)
        return result.rowcount > 0
