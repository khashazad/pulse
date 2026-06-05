"""Session persistence layer.

Provides :class:`SessionsRepository`, which owns every SQL statement against
the ``sessions`` table backing Bearer-token auth: create, lookup by token hash,
sliding-expiry update, and delete.

Sits between :mod:`SessionAuthMiddleware` / the auth router and the underlying
Postgres table definition (``repositories/tables.py``); it is the only module
in the codebase allowed to issue ``sessions`` SQL.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any, cast

from sqlalchemy import delete, insert, select, update
from sqlalchemy.engine import CursorResult
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.repositories.tables import sessions


class SessionsRepository:
    """Reads/writes for the `sessions` table backing Bearer-token auth."""

    def __init__(self, session: AsyncSession) -> None:
        """Bind the repository to an open async session.

        **Inputs:**
        - session (AsyncSession): SQLAlchemy async session used for all queries
          issued by this repository instance.
        """
        self._session = session

    async def create(
        self,
        *,
        token_hash: bytes,
        email: str,
        now: DateTimeValue,
        expires_at: DateTimeValue,
    ) -> None:
        """Insert a new Bearer-token session row for an authenticated user.

        **Inputs:**
        - token_hash (bytes): SHA-256 digest of the opaque session token.
        - email (str): Email address of the authenticated user owning the session.
        - now (DateTimeValue): Timestamp recorded as both creation and last-used time.
        - expires_at (DateTimeValue): Absolute expiry timestamp for the session.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
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
        """Fetch the session row matching the given token hash.

        **Inputs:**
        - token_hash (bytes): SHA-256 digest of the opaque session token to look up.

        **Outputs:**
        - dict[str, Any] | None: Session row mapping when found, otherwise ``None``.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
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
        """Slide a session's expiry forward and refresh its last-used timestamp.

        **Inputs:**
        - token_hash (bytes): SHA-256 digest identifying the session to update.
        - now (DateTimeValue): Timestamp written as the new last-used time.
        - new_expires_at (DateTimeValue): New absolute expiry timestamp.

        **Outputs:**
        - int: Number of rows updated (``0`` when no matching session exists).

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        result = await self._session.execute(
            update(sessions)
            .where(sessions.c.token_hash == token_hash)
            .values(last_used_at=now, expires_at=new_expires_at)
        )
        return cast(CursorResult[Any], result).rowcount or 0

    async def delete(self, token_hash: bytes) -> int:
        """Delete the session row matching the given token hash.

        **Inputs:**
        - token_hash (bytes): SHA-256 digest identifying the session to remove.

        **Outputs:**
        - int: Number of rows deleted (``0`` when no matching session exists).

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        result = await self._session.execute(
            delete(sessions).where(sessions.c.token_hash == token_hash)
        )
        return cast(CursorResult[Any], result).rowcount or 0
