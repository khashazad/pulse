"""Persistence for short-lived OAuth PKCE exchange codes.

Provides :class:`AuthExchangeCodesRepository`, owning every SQL statement
against the ``auth_exchange_codes`` table. The OAuth callback stores a hashed,
short-lived authorization code plus the PKCE ``code_challenge`` here; the app
redeems it once at ``/auth/google/exchange``. Codes are single-use: consumption
deletes the row in the same statement that reads it.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any

from sqlalchemy import delete, insert
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.repositories.tables import auth_exchange_codes


class AuthExchangeCodesRepository:
    """Reads/writes for the single-use ``auth_exchange_codes`` table."""

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
        code_hash: bytes,
        email: str,
        code_challenge: str,
        now: DateTimeValue,
        expires_at: DateTimeValue,
    ) -> None:
        """Insert a new exchange code row.

        **Inputs:**
        - code_hash (bytes): SHA-256 digest of the opaque one-time code.
        - email (str): Verified email the eventual session will belong to.
        - code_challenge (str): PKCE S256 challenge captured at authorize time.
        - now (DateTimeValue): Creation timestamp.
        - expires_at (DateTimeValue): Absolute expiry (short, e.g. ~2 minutes).

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        await self._session.execute(
            insert(auth_exchange_codes).values(
                code_hash=code_hash,
                email=email,
                code_challenge=code_challenge,
                created_at=now,
                expires_at=expires_at,
            )
        )

    async def consume(self, code_hash: bytes) -> dict[str, Any] | None:
        """Atomically delete and return the row for ``code_hash``.

        The ``DELETE ... RETURNING`` makes the code single-use: a second
        redemption (or a replay attempt) finds nothing. Expiry is enforced by
        the caller against the returned ``expires_at``.

        **Inputs:**
        - code_hash (bytes): SHA-256 digest of the presented one-time code.

        **Outputs:**
        - dict[str, Any] | None: The consumed row (``email``, ``code_challenge``,
          ``expires_at``) when present, else ``None``.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        result = await self._session.execute(
            delete(auth_exchange_codes)
            .where(auth_exchange_codes.c.code_hash == code_hash)
            .returning(
                auth_exchange_codes.c.email,
                auth_exchange_codes.c.code_challenge,
                auth_exchange_codes.c.expires_at,
            )
        )
        row = result.mappings().first()
        return dict(row) if row else None

    async def purge_expired(self, now: DateTimeValue) -> int:
        """Delete exchange codes whose expiry has passed.

        **Inputs:**
        - now (DateTimeValue): Cutoff; rows with ``expires_at <= now`` are removed.

        **Outputs:**
        - int: Number of rows deleted.

        **Exceptions:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        result = await self._session.execute(
            delete(auth_exchange_codes).where(auth_exchange_codes.c.expires_at <= now)
        )
        return result.rowcount or 0
