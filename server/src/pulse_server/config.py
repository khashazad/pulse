"""Environment-driven application settings.

Defines :class:`Settings` (a ``pydantic_settings.BaseSettings`` subclass) that
loads configuration from environment variables and ``.env``, plus
:func:`get_settings`, the cached accessor every other module uses.

Covers DB connection, USDA API key, Google OAuth (iOS-facing), MCP GitHub
OAuth (claude.ai connector-facing), session TTL, legacy single-user key, and
environment-mode guardrails that refuse to boot non-local deployments with
insecure OAuth or unauthenticated MCP configurations.
"""

from __future__ import annotations

from functools import lru_cache

from pydantic import model_validator
from pydantic_settings import BaseSettings

# Synthetic GitHub-style `login` claim attached to service-token requests so
# `GitHubAllowlistMiddleware` can gate them with the same machinery used for
# real GitHub OAuth users. Auto-injected into the effective allowlist whenever a
# service token is configured.
SERVICE_TOKEN_LOGIN = "service-account"

# Lower bound on `MCP_SERVICE_TOKEN` entropy. 32 chars ≈ 256 bits when the value
# is random hex/base64; rejects obviously-weak shared secrets.
SERVICE_TOKEN_MIN_LENGTH = 32


class Settings(BaseSettings):
    """Typed configuration for the pulse-server, sourced from env and ``.env``.

    Field defaults mirror local-dev expectations; validators enforce HTTPS
    OAuth redirects and require MCP auth (or an explicit opt-in) outside
    local/dev/test environments.
    """

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
    port: int = 8787
    timezone: str = "America/Toronto"
    app_env: str = "local"

    # MCP / claude.ai connector OAuth (separate from Google iOS auth).
    github_client_id: str = ""
    github_client_secret: str = ""
    allowed_github_users: str = ""
    public_base_url: str = ""

    # Explicit opt-in to run the MCP layer without auth. Only honored when APP_ENV is
    # local/dev/test; non-local envs always require GitHub OAuth or a service token.
    mcp_allow_unauth: bool = False

    # Static bearer token for headless agents (e.g. Hermes). When set, requests
    # carrying `Authorization: Bearer <token>` are accepted alongside any
    # configured GitHub OAuth flow. Empty disables this path.
    mcp_service_token: str = ""

    model_config = {
        "env_prefix": "",
        "case_sensitive": False,
        "env_file": ".env",
        "env_file_encoding": "utf-8",
        "extra": "ignore",
    }

    @property
    def allowed_emails_set(self) -> set[str]:
        """Return the allow-listed Google emails as a normalized lowercase set.

        **Outputs:**
        - set[str]: Trimmed, lowercased entries parsed from the comma-separated
          ``ALLOWED_EMAILS`` value (empty when unset).
        """
        return {e.strip().lower() for e in self.allowed_emails.split(",") if e.strip()}

    @property
    def github_users_allowlist(self) -> set[str]:
        """Return the operator-configured GitHub usernames, without the synthetic login.

        This is the raw ``ALLOWED_GITHUB_USERS`` parse used by the prod
        fail-closed validator; it deliberately excludes the auto-injected
        service-token login so an empty result means "operator set no human
        allowlist."

        **Outputs:**
        - set[str]: Trimmed, lowercased entries parsed from
          ``ALLOWED_GITHUB_USERS`` (empty when unset).
        """
        return {u.strip().lower() for u in self.allowed_github_users.split(",") if u.strip()}

    @property
    def allowed_github_users_set(self) -> set[str]:
        """Return the allow-listed GitHub usernames for MCP OAuth as a lowercase set.

        Auto-includes ``SERVICE_TOKEN_LOGIN`` when a service token is configured
        so that headless agents pass ``GitHubAllowlistMiddleware`` without the
        operator having to remember to add the synthetic login alongside their
        real GitHub usernames.

        **Outputs:**
        - set[str]: Trimmed, lowercased entries parsed from
          ``ALLOWED_GITHUB_USERS`` (empty when unset), plus the service-token
          synthetic login when ``mcp_service_token_enabled``.
        """
        base = self.github_users_allowlist
        # Only auto-add when the operator already opted into gating; an empty
        # allowlist means open-mode and the middleware short-circuits anyway.
        if base and self.mcp_service_token_enabled:
            base.add(SERVICE_TOKEN_LOGIN)
        return base

    @property
    def mcp_service_token_enabled(self) -> bool:
        """Indicate whether a static service-token bearer is configured.

        **Outputs:**
        - bool: ``True`` when ``MCP_SERVICE_TOKEN`` is set to a non-empty value.
        """
        return bool(self.mcp_service_token)

    @property
    def mcp_oauth_enabled(self) -> bool:
        """Indicate whether GitHub OAuth is configured for the MCP layer.

        **Outputs:**
        - bool: ``True`` when client id, client secret, and public base URL are
          all set.
        """
        return bool(self.github_client_id and self.github_client_secret and self.public_base_url)

    @property
    def is_local_env(self) -> bool:
        """Indicate whether the app is running in a local-style environment.

        **Outputs:**
        - bool: ``True`` when ``APP_ENV`` is one of ``local``, ``dev``, ``test``.
        """
        return (self.app_env or "").lower() in {"local", "dev", "test"}

    @model_validator(mode="after")
    def _enforce_https_redirect_outside_local(self) -> Settings:
        """Reject non-HTTPS OAuth redirect URIs outside local-style environments.

        **Outputs:**
        - Settings: This instance, unchanged, when validation passes.

        **Exceptions:**
        - ValueError: Raised when ``OAUTH_REDIRECT_URI`` is set but not HTTPS
          in a non-local environment.
        """
        if self.is_local_env:
            return self
        if self.oauth_redirect_uri and not self.oauth_redirect_uri.startswith("https://"):
            raise ValueError("OAUTH_REDIRECT_URI must use https in non-local environments")
        return self

    @model_validator(mode="after")
    def _require_mcp_auth_outside_local(self) -> Settings:
        """Refuse to boot non-local deployments with an unauthenticated MCP layer.

        ``/mcp`` is exempt from ``SessionAuthMiddleware`` so the MCP layer must
        own its own auth. Non-local envs must configure GitHub OAuth
        (``mcp_oauth_enabled``) or explicitly opt in to unauthenticated MCP
        via ``MCP_ALLOW_UNAUTH=true`` (intended for local dev).

        **Outputs:**
        - Settings: This instance, unchanged, when validation passes.

        **Exceptions:**
        - ValueError: Raised when MCP is unauthenticated and the environment is
          not local/dev/test and no explicit opt-in is provided.
        """
        if self.is_local_env:
            return self
        if (
            not self.mcp_oauth_enabled
            and not self.mcp_service_token_enabled
            and not self.mcp_allow_unauth
        ):
            raise ValueError(
                "MCP layer is unauthenticated: set GITHUB_CLIENT_ID/SECRET + PUBLIC_BASE_URL "
                "to enable GitHub OAuth, set MCP_SERVICE_TOKEN for a static bearer, "
                "or MCP_ALLOW_UNAUTH=true to opt in explicitly"
            )
        return self

    @model_validator(mode="after")
    def _require_github_allowlist_with_oauth(self) -> Settings:
        """Refuse to boot non-local deployments that enable GitHub OAuth with an empty allowlist.

        ``GitHubAllowlistMiddleware`` runs in open-mode (passes every caller)
        when the allowlist is empty, so GitHub OAuth without
        ``ALLOWED_GITHUB_USERS`` lets any GitHub account invoke the
        single-tenant MCP tools. ``/mcp`` is exempt from
        ``SessionAuthMiddleware``, so the allowlist is the only owner check on
        the OAuth path — it must be non-empty in production. Local/dev/test keep
        open-mode for convenience; the service-token-only path is unaffected
        because the static verifier already restricts callers to the token.

        **Outputs:**
        - Settings: This instance, unchanged, when validation passes.

        **Exceptions:**
        - ValueError: Raised when GitHub OAuth is enabled outside a local-style
          environment but ``ALLOWED_GITHUB_USERS`` is empty.
        """
        if self.is_local_env:
            return self
        if self.mcp_oauth_enabled and not self.github_users_allowlist:
            raise ValueError(
                "GitHub OAuth is enabled but ALLOWED_GITHUB_USERS is empty: an empty "
                "allowlist lets any GitHub account call the MCP tools. Set "
                "ALLOWED_GITHUB_USERS to the permitted GitHub usernames."
            )
        return self

    @model_validator(mode="after")
    def _require_strong_service_token(self) -> Settings:
        """Reject short ``MCP_SERVICE_TOKEN`` values that would be trivially guessable.

        **Outputs:**
        - Settings: This instance, unchanged, when validation passes.

        **Exceptions:**
        - ValueError: Raised when ``MCP_SERVICE_TOKEN`` is set but shorter than
          :data:`SERVICE_TOKEN_MIN_LENGTH`.
        """
        if self.mcp_service_token and len(self.mcp_service_token) < SERVICE_TOKEN_MIN_LENGTH:
            raise ValueError(
                f"MCP_SERVICE_TOKEN must be at least {SERVICE_TOKEN_MIN_LENGTH} characters"
            )
        return self


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return the process-wide :class:`Settings` instance, constructed once.

    **Outputs:**
    - Settings: Cached settings parsed from environment variables and ``.env``.

    **Exceptions:**
    - pydantic_core.ValidationError: Raised when required settings are missing
      or validators reject the configuration.
    """
    # pydantic-settings populates required fields from the environment at runtime,
    # which mypy cannot see — hence the call-arg ignore.
    return Settings()  # type: ignore[call-arg]
