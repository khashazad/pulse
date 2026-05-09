from __future__ import annotations

from fastapi import Header, HTTPException

_configured_key: str = ""


# Summary: Configures the expected API key used by request authentication.
# Parameters:
# - api_key (str): Shared API key value accepted by protected endpoints.
# Returns:
# - None: Updates module-level auth configuration.
# Raises/Throws:
# - None: The function stores the supplied key without validation.
def configure(api_key: str) -> None:
    global _configured_key
    _configured_key = api_key


# Summary: Validates the `X-API-Key` header against the configured shared key.
# Parameters:
# - x_api_key (str): API key header value supplied by the client request.
# Returns:
# - str: The validated API key value when authentication succeeds.
# Raises/Throws:
# - fastapi.HTTPException: Raised with 401 status for missing or mismatched keys.
async def require_api_key(x_api_key: str = Header(alias="X-API-Key", default="")) -> str:
    if not _configured_key or x_api_key != _configured_key:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return x_api_key
