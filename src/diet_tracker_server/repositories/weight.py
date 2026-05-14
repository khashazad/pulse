from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from decimal import Decimal
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession


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
        raise NotImplementedError

    async def list_range(
        self,
        user_key: str,
        from_date: DateValue,
        to_date: DateValue,
    ) -> list[dict[str, Any]]:
        raise NotImplementedError

    async def get_by_date(
        self,
        user_key: str,
        log_date: DateValue,
    ) -> dict[str, Any] | None:
        raise NotImplementedError

    async def delete(
        self,
        user_key: str,
        log_date: DateValue,
    ) -> bool:
        raise NotImplementedError
