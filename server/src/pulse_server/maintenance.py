"""Best-effort startup maintenance jobs.

Houses housekeeping that should run opportunistically at boot but must never
block or fail a deployment: purging expired session rows and expired OAuth
exchange codes. Both tables are append-mostly (expiry was previously enforced
only lazily on lookup), so without this they grow without bound.
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime

from pulse_server.db import get_session
from pulse_server.repositories.auth_exchange_codes import AuthExchangeCodesRepository
from pulse_server.repositories.sessions import SessionsRepository

logger = logging.getLogger(__name__)


async def purge_expired_auth_rows() -> None:
    """Delete expired ``sessions`` and ``auth_exchange_codes`` rows.

    Called from the app lifespan after the pool is initialized. Failures are
    logged and swallowed: pruning is housekeeping, and a transient DB error
    here must not prevent the service from booting (the rows are merely stale,
    not dangerous — both tables store only hashes).

    **Outputs:**
    - None: Returns nothing.
    """
    now = datetime.now(UTC)
    try:
        async with get_session() as db_session:
            sessions_purged = await SessionsRepository(db_session).purge_expired(now)
            codes_purged = await AuthExchangeCodesRepository(db_session).purge_expired(now)
            await db_session.commit()
    except Exception:
        logger.warning("startup purge of expired auth rows failed", exc_info=True)
        return
    if sessions_purged or codes_purged:
        logger.info(
            "purged %d expired sessions and %d expired exchange codes",
            sessions_purged,
            codes_purged,
        )
