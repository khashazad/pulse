from __future__ import annotations

from functools import lru_cache
from typing import Any

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str
    usda_api_key: str
    api_key: str
    default_user_key: str = "default"
    port: int = 8787
    timezone: str = "America/Toronto"
    # OAuth (claude.ai connector path). Empty values disable OAuth; the MCP layer falls back to X-API-Key.
    github_client_id: str = ""
    github_client_secret: str = ""
    allowed_github_users: str = ""  # comma-separated GitHub logins
    public_base_url: str = ""

    model_config = {"env_prefix": "", "case_sensitive": False, "env_file": ".env", "env_file_encoding": "utf-8", "extra": "ignore"}

    @property
    def allowed_github_users_set(self) -> set[str]:
        return {u.strip().lower() for u in self.allowed_github_users.split(",") if u.strip()}

    @property
    def oauth_enabled(self) -> bool:
        return bool(self.github_client_id and self.github_client_secret and self.public_base_url)


# Summary: Returns a cached Settings instance for application-level use.
# Parameters:
# - None: Uses process environment for configuration values.
# Returns:
# - Settings: Cached validated runtime settings.
# Raises/Throws:
# - pydantic_core.ValidationError: Raised if configuration is incomplete or invalid.
@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
