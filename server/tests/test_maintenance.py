"""Unit tests for the best-effort startup maintenance in :mod:`maintenance`.

Covers the happy path (both repositories purged inside one committed session)
and the failure guarantee: a DB error during the purge is logged and swallowed
so it can never block application boot.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, patch

from pulse_server.maintenance import purge_expired_auth_rows


def _fake_session_ctx() -> tuple[AsyncMock, AsyncMock]:
    """Build a fake ``get_session`` async context manager and its session.

    **Outputs:**
    - tuple[AsyncMock, AsyncMock]: ``(ctx, session)`` where ``ctx`` is suitable
      as the return value of a patched ``get_session``.
    """
    session = AsyncMock()
    ctx = AsyncMock()
    ctx.__aenter__.return_value = session
    ctx.__aexit__.return_value = None
    return ctx, session


async def test_purges_both_tables_and_commits() -> None:
    """Both repositories' `purge_expired` run and the session commits once."""
    ctx, session = _fake_session_ctx()
    sessions_repo = AsyncMock()
    sessions_repo.purge_expired.return_value = 3
    codes_repo = AsyncMock()
    codes_repo.purge_expired.return_value = 2
    with (
        patch("pulse_server.maintenance.get_session", return_value=ctx),
        patch("pulse_server.maintenance.SessionsRepository", return_value=sessions_repo),
        patch("pulse_server.maintenance.AuthExchangeCodesRepository", return_value=codes_repo),
    ):
        await purge_expired_auth_rows()
    sessions_repo.purge_expired.assert_awaited_once()
    codes_repo.purge_expired.assert_awaited_once()
    session.commit.assert_awaited_once()


async def test_db_failure_is_swallowed() -> None:
    """A purge failure logs and returns instead of propagating to the lifespan."""
    with patch(
        "pulse_server.maintenance.get_session",
        side_effect=RuntimeError("Database pool not initialized"),
    ):
        # Must not raise — boot continues without the purge.
        await purge_expired_auth_rows()
