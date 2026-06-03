"""Process-scoped USDA client holder and FastAPI dependency.

Owns the module-level :class:`USDAClient` instance created during the FastAPI
lifespan and exposes it both as a plain getter (for the MCP layer, which takes
a zero-arg callable) and as a FastAPI dependency (for HTTP routers). Living in
its own module lets ``routers/usda.py`` depend on the live client without
importing ``app.py`` — removing the prior lazy-import-inside-the-handler hack
and the router → app circular dependency it worked around.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends

from pulse_server.usda import USDAClient

_usda_client: USDAClient | None = None


def set_usda_client(client: USDAClient | None) -> None:
    """Set (or clear) the process-scoped USDA client.

    Called by the app lifespan to publish the client at startup and clear it at
    shutdown.

    **Inputs:**
    - client (USDAClient | None): The live client to publish, or ``None`` to
      clear the slot during shutdown.

    **Outputs:**
    - None: Mutates module state and returns nothing.
    """
    global _usda_client
    _usda_client = client


def get_usda_client() -> USDAClient:
    """Return the initialized USDA client used by API routers and the MCP layer.

    **Outputs:**
    - USDAClient: Configured client for USDA FoodData Central requests.

    **Raises:**
    - RuntimeError: Raised when called before lifespan startup publishes the
      client.
    """
    if _usda_client is None:
        raise RuntimeError("USDA client not initialized")
    return _usda_client


# FastAPI dependency alias: routers annotate a parameter with this to receive
# the live client, replacing the lazy ``from pulse_server.app import ...`` import.
USDAClientDep = Annotated[USDAClient, Depends(get_usda_client)]
