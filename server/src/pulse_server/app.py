"""FastAPI application entry point and ASGI wiring.

Constructs the ``app`` instance: registers the lifespan that initializes the
SQLAlchemy pool, bootstraps schema, and owns the USDA client; installs the
session-auth middleware (with MCP path exemptions);
mounts every feature router; and grafts the FastMCP server plus its OAuth
metadata routes at ``/mcp``.

This module is the composition root of the backend — uvicorn imports ``app``
from here and every cross-cutting concern (auth, DB, MCP, USDA) is wired up
in this file.
"""

from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastmcp.utilities.lifespan import combine_lifespans

from pulse_server import db
from pulse_server.auth import SessionAuthMiddleware
from pulse_server.config import get_settings
from pulse_server.maintenance import purge_expired_auth_rows
from pulse_server.mcp import build_mcp
from pulse_server.mcp.storage import aclose_client_storage
from pulse_server.observability import init_sentry, request_logging_middleware
from pulse_server.photo_store import build_photo_store, set_photo_store
from pulse_server.routers import activity as activity_router
from pulse_server.routers import auth as auth_router
from pulse_server.routers import (
    containers as containers_router,
)
from pulse_server.routers import (
    custom_foods as custom_foods_router,
)
from pulse_server.routers import (
    entries,
    logs,
    summary,
    targets,
)
from pulse_server.routers import (
    food_memory as food_memory_router,
)
from pulse_server.routers import (
    foods as foods_router,
)
from pulse_server.routers import (
    meals as meals_router,
)
from pulse_server.routers import (
    measures_photo_tags as measures_photo_tags_router,
)
from pulse_server.routers import (
    measures_photos as measures_photos_router,
)
from pulse_server.routers import usda as usda_router
from pulse_server.routers import (
    weight as weight_router,
)
from pulse_server.usda import USDAClient
from pulse_server.usda_provider import get_usda_client, set_usda_client


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage startup and shutdown resources for the FastAPI application.

    Initializes the SQLAlchemy pool, bootstraps the schema, constructs the
    shared USDA client and publishes it to :mod:`pulse_server.usda_provider`,
    builds the progress-photo object store and publishes it to
    :mod:`pulse_server.photo_store`, yields while the app is running, then tears
    down the photo store, USDA client, MCP OAuth-state store pool, and pool.

    **Inputs:**
    - app (FastAPI): Active FastAPI application instance bound to this lifespan.

    **Outputs:**
    - None: Async context manager; yields control while the app runs.

    **Raises:**
    - pydantic_core.ValidationError: Raised when required settings are missing.
    - psycopg.Error: Raised when database initialization or schema bootstrap fails.
    - httpx.HTTPError: Raised if USDA client shutdown encounters transport issues.
    """
    del app
    settings = get_settings()
    init_sentry(settings)
    await db.init_pool(settings.database_url)
    await db.bootstrap_schema()
    await purge_expired_auth_rows()
    usda_client = USDAClient(settings.usda_api_key)
    set_usda_client(usda_client)
    set_photo_store(build_photo_store(settings))
    yield
    set_photo_store(None)
    await usda_client.close()
    set_usda_client(None)
    # Drain the MCP OAuth-state store's asyncpg pool (no-op when persistence
    # is unconfigured or the pool was never opened) before the app DB pool.
    await aclose_client_storage()
    await db.close_pool()


mcp = build_mcp(get_usda_client)
mcp_app = mcp.http_app(path="/")

app = FastAPI(
    title="Diet Server",
    version="0.1.0",
    lifespan=combine_lifespans(lifespan, mcp_app.lifespan),
)

# MCP and FastMCP-emitted OAuth routes must bypass the diet session middleware. The MCP
# layer has its own auth (GitHub OAuth or unauth in local dev); session bearer tokens
# don't apply there.
_mcp_exempt_paths: frozenset[str] = frozenset(
    route.path
    for route in (mcp.auth.get_routes(mcp_path="/mcp/") if mcp.auth is not None else [])
    if hasattr(route, "path")
)
_mcp_exempt_prefixes: tuple[str, ...] = ("/mcp",)

app.add_middleware(
    SessionAuthMiddleware,
    exempt_paths=_mcp_exempt_paths,
    exempt_prefixes=_mcp_exempt_prefixes,
)

# Registered after (= runs outside) the auth middleware so 401s are logged too.
app.middleware("http")(request_logging_middleware)


@app.get("/health")
async def health() -> dict[str, str]:
    """Return a simple health status payload for service monitoring.

    **Outputs:**
    - dict[str, str]: Static health payload with service status.
    """
    return {"status": "ok"}


app.include_router(auth_router.router)
app.include_router(entries.router)
app.include_router(summary.router)
app.include_router(targets.router)
app.include_router(usda_router.router)
app.include_router(logs.router)
app.include_router(containers_router.router)
app.include_router(custom_foods_router.router)
app.include_router(foods_router.router)
app.include_router(food_memory_router.router)
app.include_router(meals_router.router)
app.include_router(weight_router.router)
app.include_router(measures_photo_tags_router.router)
app.include_router(measures_photos_router.router)
app.include_router(activity_router.router)

# OAuth metadata routes (.well-known/oauth-authorization-server, /authorize, /token, etc.)
# must live at the root so claude.ai's connector can discover them. The MCP server itself
# stays mounted at /mcp.
if mcp.auth is not None:
    for route in mcp.auth.get_routes(mcp_path="/mcp/"):
        app.routes.append(route)

app.mount("/mcp", mcp_app)
