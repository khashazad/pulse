from __future__ import annotations

import json
import os
from functools import lru_cache
from pathlib import Path
from typing import Any

from pydantic_settings import BaseSettings


# Summary: Reads legacy nutrition tracker credentials and maps them to server env keys.
# Parameters:
# - None: The function loads from the default credential path in the user's home directory.
# Returns:
# - dict[str, str]: Environment-style key/value pairs derived from legacy config when available.
# Raises/Throws:
# - None: Missing files or malformed payloads are treated as absent legacy configuration.
def _load_legacy_config() -> dict[str, str]:
    path = Path.home() / ".clawdbot/credentials/nutrition-tracker/config.json"
    if not path.exists():
        return {}

    try:
        raw: dict[str, Any] = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return {}

    mapping = {
        "supabaseDbUrl": "DATABASE_URL",
        "usdaApiKey": "USDA_API_KEY",
    }
    return {
        env_key: str(raw[json_key])
        for json_key, env_key in mapping.items()
        if raw.get(json_key)
    }


_LEGACY = _load_legacy_config()


class Settings(BaseSettings):
    database_url: str
    usda_api_key: str
    api_key: str
    default_user_key: str = "default"
    port: int = 8787
    timezone: str = "America/Toronto"

    model_config = {"env_prefix": "", "case_sensitive": False}

    # Summary: Builds validated settings from legacy config, process env, and explicit overrides.
    # Parameters:
    # - kwargs (Any): Explicit field overrides passed by callers, applied last.
    # Returns:
    # - None: Initializes the Settings instance in place.
    # Raises/Throws:
    # - pydantic_core.ValidationError: Raised when required values are missing or invalid.
    def __init__(self, **kwargs: Any) -> None:
        legacy_fields: dict[str, Any] = {}
        if _LEGACY.get("DATABASE_URL") and "DATABASE_URL" not in os.environ:
            legacy_fields["database_url"] = _LEGACY["DATABASE_URL"]
        if _LEGACY.get("USDA_API_KEY") and "USDA_API_KEY" not in os.environ:
            legacy_fields["usda_api_key"] = _LEGACY["USDA_API_KEY"]
        merged: dict[str, Any] = {**legacy_fields}
        merged.update(kwargs)
        super().__init__(**merged)


# Summary: Returns a cached Settings instance for application-level use.
# Parameters:
# - None: Uses process environment and optional legacy fallback values.
# Returns:
# - Settings: Cached validated runtime settings.
# Raises/Throws:
# - pydantic_core.ValidationError: Raised if configuration is incomplete or invalid.
@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
