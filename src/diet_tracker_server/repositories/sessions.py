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

    # Summary: Inserts a new Bearer-token session row for an authenticated user.
    # Parameters:
    # - token_hash (bytes): SHA-256 digest of the opaque session token.
    # - email (str): Email address of the authenticated user owning the session.
    # - now (DateTimeValue): Timestamp recorded as both creation and last-used time.
    # - expires_at (DateTimeValue): Absolute expiry timestamp for the session.
    # Returns:
    # - None: Executes insert side effect only.
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
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

    # Summary: Fetches the session row matching the given token hash.
    # Parameters:
    # - token_hash (bytes): SHA-256 digest of the opaque session token to look up.
    # Returns:
    # - dict[str, Any] | None: Session row mapping when found, otherwise None.
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    async def get(self, token_hash: bytes) -> dict[str, Any] | None:
        result = await self._session.execute(
            select(sessions).where(sessions.c.token_hash == token_hash)
        )
        row = result.mappings().first()
        return dict(row) if row else None

    # Summary: Slides a session's expiry forward and updates its last-used timestamp.
    # Parameters:
    # - token_hash (bytes): SHA-256 digest identifying the session to update.
    # - now (DateTimeValue): Timestamp written as the new last-used time.
    # - new_expires_at (DateTimeValue): New absolute expiry timestamp for the session.
    # Returns:
    # - int: Number of rows updated (0 when no matching session exists).
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
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

    # Summary: Deletes the session row matching the given token hash.
    # Parameters:
    # - token_hash (bytes): SHA-256 digest identifying the session to remove.
    # Returns:
    # - int: Number of rows deleted (0 when no matching session exists).
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    async def delete(self, token_hash: bytes) -> int:
        result = await self._session.execute(
            delete(sessions).where(sessions.c.token_hash == token_hash)
        )
        return result.rowcount or 0
