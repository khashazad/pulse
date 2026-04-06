from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI

from nutrition_server import auth, db
from nutrition_server.config import get_settings
from nutrition_server.routers import entries
from nutrition_server.usda import USDAClient

usda_client: USDAClient | None = None


# Summary: Returns the initialized USDA client used by API routers.
# Parameters:
# - None: Uses module-level USDA client state initialized during app lifespan.
# Returns:
# - USDAClient: Configured client for USDA FoodData Central requests.
# Raises/Throws:
# - RuntimeError: Raised when called before startup initialization completes.
def get_usda_client() -> USDAClient:
    if usda_client is None:
        raise RuntimeError("USDA client not initialized")
    return usda_client


# Summary: Manages startup and shutdown resources for the FastAPI application.
# Parameters:
# - app (FastAPI): Active FastAPI application instance bound to this lifespan.
# Returns:
# - None: Yields control while the application is running.
# Raises/Throws:
# - pydantic_core.ValidationError: Raised when required settings are missing.
# - psycopg.Error: Raised when database initialization or schema bootstrap fails.
# - httpx.HTTPError: Raised if USDA client shutdown encounters transport issues.
@asynccontextmanager
async def lifespan(app: FastAPI):
    del app
    global usda_client
    settings = get_settings()
    auth.configure(settings.api_key)
    await db.init_pool(settings.database_url)
    await db.bootstrap_schema()
    usda_client = USDAClient(settings.usda_api_key)
    yield
    await usda_client.close()
    await db.close_pool()


app = FastAPI(title="Nutrition Server", version="0.1.0", lifespan=lifespan)


# Summary: Returns a simple health status payload for service monitoring.
# Parameters:
# - None: Endpoint does not require inputs.
# Returns:
# - dict[str, str]: Static health payload with service status.
# Raises/Throws:
# - None: Endpoint always returns a static success payload.
@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}

app.include_router(entries.router)
