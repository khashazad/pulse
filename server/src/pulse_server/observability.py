"""Request logging and error-reporting wiring.

Provides the per-request access-log middleware and optional Sentry
initialization. Before this module existed the service emitted no request
logs and no error reports at all — a production 500 was invisible unless the
Railway deploy logs happened to be open.
"""

from __future__ import annotations

import logging
import time

from fastapi import Request

from pulse_server.config import Settings

logger = logging.getLogger("pulse_server.requests")


def init_sentry(settings: Settings) -> bool:
    """Initialize Sentry error reporting when a DSN is configured.

    Import is deferred so the dependency stays optional at runtime: with no
    ``SENTRY_DSN`` set, ``sentry_sdk`` is never imported. Only unhandled
    exceptions are reported (no performance tracing) to stay comfortably
    inside the free tier.

    **Inputs:**
    - settings (Settings): Active app settings; ``sentry_dsn`` gates the init.

    **Outputs:**
    - bool: ``True`` when Sentry was initialized, ``False`` when disabled.
    """
    if not settings.sentry_dsn:
        return False
    import sentry_sdk

    sentry_sdk.init(
        dsn=settings.sentry_dsn,
        environment=settings.app_env,
        traces_sample_rate=0.0,
        send_default_pii=False,
    )
    logger.info("sentry error reporting enabled (env=%s)", settings.app_env)
    return True


async def request_logging_middleware(request: Request, call_next):
    """Log one line per request: method, path, status, and duration.

    Registered via ``app.middleware("http")``. Unhandled exceptions are logged
    with a stack trace (and re-raised so Sentry/Starlette handle them); the
    query string is deliberately omitted from the log line because auth
    bootstrap routes carry OAuth state in the query.

    **Inputs:**
    - request (Request): Incoming HTTP request.
    - call_next (Callable): Downstream handler chain.

    **Outputs:**
    - Response: The downstream response, unmodified.

    **Raises:**
    - Exception: Re-raises whatever the downstream handler raised, after logging.
    """
    start = time.monotonic()
    try:
        response = await call_next(request)
    except Exception:
        elapsed_ms = (time.monotonic() - start) * 1000
        logger.exception(
            "%s %s -> unhandled error (%.1fms)", request.method, request.url.path, elapsed_ms
        )
        raise
    elapsed_ms = (time.monotonic() - start) * 1000
    logger.info(
        "%s %s -> %d (%.1fms)",
        request.method,
        request.url.path,
        response.status_code,
        elapsed_ms,
    )
    return response
