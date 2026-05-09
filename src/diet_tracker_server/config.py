from __future__ import annotations

from functools import lru_cache

from pydantic import model_validator
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str
    usda_api_key: str

    # Google OAuth (iOS-facing).
    google_client_id: str = ""
    google_client_secret: str = ""
    oauth_redirect_uri: str = ""
    app_redirect_scheme: str = "diettracker"
    allowed_emails: str = ""  # comma-separated
    session_ttl_days: int = 90
    session_token_bytes: int = 32
    legacy_user_key: str = "khash"

    # Existing.
    default_user_key: str = "default"
    port: int = 8787
    timezone: str = "America/Toronto"
    app_env: str = "local"

    # MCP / claude.ai connector OAuth (separate from Google iOS auth).
    github_client_id: str = ""
    github_client_secret: str = ""
    allowed_github_users: str = ""
    public_base_url: str = ""

    model_config = {
        "env_prefix": "",
        "case_sensitive": False,
        "env_file": ".env",
        "env_file_encoding": "utf-8",
        "extra": "ignore",
    }

    @property
    def allowed_emails_set(self) -> set[str]:
        return {e.strip().lower() for e in self.allowed_emails.split(",") if e.strip()}

    @property
    def allowed_github_users_set(self) -> set[str]:
        return {u.strip().lower() for u in self.allowed_github_users.split(",") if u.strip()}

    @property
    def mcp_oauth_enabled(self) -> bool:
        return bool(self.github_client_id and self.github_client_secret and self.public_base_url)

    @model_validator(mode="after")
    def _enforce_https_redirect_outside_local(self) -> "Settings":
        env = (self.app_env or "").lower()
        if env in {"local", "dev", "test"}:
            return self
        if self.oauth_redirect_uri and not self.oauth_redirect_uri.startswith("https://"):
            raise ValueError("OAUTH_REDIRECT_URI must use https in non-local environments")
        return self


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
