from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any

from sqlalchemy import delete, insert, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.repositories.tables import sessions


class SessionsRepository:
    """Reads/writes for the `sessions` table backing Bearer-token auth."""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def create(
        self,
        *,
        token_hash: bytes,
        email: str,
        now: DateTimeValue,
        expires_at: DateTimeValue,
    ) -> None:
        await self._session.execute(
            insert(sessions).values(
                token_hash=token_hash,
                email=email,
                created_at=now,
                last_used_at=now,
                expires_at=expires_at,
            )
        )

    async def get(self, token_hash: bytes) -> dict[str, Any] | None:
        result = await self._session.execute(
            select(sessions).where(sessions.c.token_hash == token_hash)
        )
        row = result.mappings().first()
        return dict(row) if row else None

    async def slide(
        self,
        *,
        token_hash: bytes,
        now: DateTimeValue,
        new_expires_at: DateTimeValue,
    ) -> int:
        result = await self._session.execute(
            update(sessions)
            .where(sessions.c.token_hash == token_hash)
            .values(last_used_at=now, expires_at=new_expires_at)
        )
        return result.rowcount or 0

    async def delete(self, token_hash: bytes) -> int:
        result = await self._session.execute(
            delete(sessions).where(sessions.c.token_hash == token_hash)
        )
        return result.rowcount or 0
