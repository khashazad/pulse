"""Unit tests for `pulse_server.config.Settings`.

Covers env-var loading, removal of the legacy `API_KEY` field, lowercased
allow-list parsing, HTTPS enforcement on the OAuth redirect URI outside
`local`, and the MCP-unauth gating logic (rejected outside `local`
without an explicit opt-in or GitHub OAuth configuration, allowed in
`local` by default).
"""

from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def _isolate_env(monkeypatch):
    """Wipe and reseed every relevant env var to isolate `Settings` tests.

    **Inputs:**
    - monkeypatch (pytest.MonkeyPatch): Used to manage env var state.
    """
    for k in (
        "API_KEY",
        "GOOGLE_CLIENT_ID",
        "GOOGLE_CLIENT_SECRET",
        "OAUTH_REDIRECT_URI",
        "APP_REDIRECT_SCHEME",
        "ALLOWED_EMAILS",
        "SESSION_TTL_DAYS",
        "SESSION_TOKEN_BYTES",
        "LEGACY_USER_KEY",
        "APP_ENV",
        "GITHUB_CLIENT_ID",
        "GITHUB_CLIENT_SECRET",
        "ALLOWED_GITHUB_USERS",
        "PUBLIC_BASE_URL",
        "MCP_ALLOW_UNAUTH",
        "MCP_SERVICE_TOKEN",
        "MCP_JWT_SIGNING_KEY",
        "MCP_STORAGE_ENCRYPTION_KEY",
        "S3_ENDPOINT",
        "S3_BUCKET",
        "S3_ACCESS_KEY_ID",
        "S3_SECRET_ACCESS_KEY",
    ):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("DATABASE_URL", "postgresql://localhost/test")
    monkeypatch.setenv("USDA_API_KEY", "x")
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "cid")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "secret")
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "https://api.example.com/auth/google/callback")
    monkeypatch.setenv("APP_REDIRECT_SCHEME", "diettracker")
    monkeypatch.setenv("ALLOWED_EMAILS", "khashzd@gmail.com,Other@Example.com")
    monkeypatch.setenv("LEGACY_USER_KEY", "khash")
    yield


def test_settings_has_no_api_key_field():
    """`Settings` no longer carries the legacy `api_key` field."""
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert not hasattr(s, "api_key"), "api_key must be removed"


def test_settings_loads_oauth_envs():
    """`Settings` populates Google OAuth fields and TTL defaults from env."""
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.google_client_id == "cid"
    assert s.google_client_secret == "secret"
    assert s.oauth_redirect_uri == "https://api.example.com/auth/google/callback"
    assert s.app_redirect_scheme == "diettracker"
    assert s.legacy_user_key == "khash"
    assert s.session_ttl_days == 90
    assert s.session_token_bytes == 32


def test_allowed_emails_set_lowercased():
    """`allowed_emails_set` lowercases every entry parsed from the env var."""
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.allowed_emails_set == {"khashzd@gmail.com", "other@example.com"}


def test_redirect_uri_must_be_https_outside_local(monkeypatch):
    """Non-HTTPS `OAUTH_REDIRECT_URI` outside `APP_ENV=local` raises `ValueError`."""
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "http://api.example.com/auth/google/callback")
    monkeypatch.setenv("APP_ENV", "prod")
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    with pytest.raises(ValueError, match="must use https"):
        cfg.get_settings()


def test_redirect_uri_http_allowed_for_local(monkeypatch):
    """`http://localhost` redirect URIs are accepted when `APP_ENV=local`."""
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "http://localhost:8787/auth/google/callback")
    monkeypatch.setenv("APP_ENV", "local")
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.oauth_redirect_uri.startswith("http://localhost")


def test_mcp_unauth_rejected_outside_local(monkeypatch):
    """Non-local env with no GitHub OAuth and no `MCP_ALLOW_UNAUTH` opt-in raises."""
    # Non-local env, no GitHub OAuth, no opt-in → must raise.
    monkeypatch.setenv("APP_ENV", "prod")
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    with pytest.raises(ValueError, match="MCP layer is unauthenticated"):
        cfg.get_settings()


def test_mcp_unauth_allowed_outside_local_with_explicit_optin(monkeypatch):
    """Explicit `MCP_ALLOW_UNAUTH=true` permits MCP unauth outside `local` without GitHub OAuth."""
    monkeypatch.setenv("APP_ENV", "prod")
    monkeypatch.setenv("MCP_ALLOW_UNAUTH", "true")
    monkeypatch.setenv("S3_ENDPOINT", "https://acc.r2.cloudflarestorage.com")
    monkeypatch.setenv("S3_BUCKET", "pulse-photos")
    monkeypatch.setenv("S3_ACCESS_KEY_ID", "ak")
    monkeypatch.setenv("S3_SECRET_ACCESS_KEY", "sk")
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.mcp_allow_unauth is True
    assert s.mcp_oauth_enabled is False


def test_mcp_unauth_allowed_outside_local_with_github_oauth(monkeypatch):
    """Configuring GitHub OAuth (with an allowlist) in prod enables MCP OAuth and clears the unauth gate."""
    monkeypatch.setenv("APP_ENV", "prod")
    monkeypatch.setenv("GITHUB_CLIENT_ID", "ghcid")
    monkeypatch.setenv("GITHUB_CLIENT_SECRET", "ghsecret")
    monkeypatch.setenv("PUBLIC_BASE_URL", "https://api.example.com")
    monkeypatch.setenv("ALLOWED_GITHUB_USERS", "khashazad")
    monkeypatch.setenv("S3_ENDPOINT", "https://acc.r2.cloudflarestorage.com")
    monkeypatch.setenv("S3_BUCKET", "pulse-photos")
    monkeypatch.setenv("S3_ACCESS_KEY_ID", "ak")
    monkeypatch.setenv("S3_SECRET_ACCESS_KEY", "sk")
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.mcp_oauth_enabled is True


def test_github_oauth_without_allowlist_rejected_in_prod(monkeypatch):
    """Prod GitHub OAuth with an empty ALLOWED_GITHUB_USERS fails closed at load time."""
    monkeypatch.setenv("APP_ENV", "prod")
    monkeypatch.setenv("GITHUB_CLIENT_ID", "ghcid")
    monkeypatch.setenv("GITHUB_CLIENT_SECRET", "ghsecret")
    monkeypatch.setenv("PUBLIC_BASE_URL", "https://api.example.com")
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    with pytest.raises(ValueError, match="ALLOWED_GITHUB_USERS is empty"):
        cfg.get_settings()


def test_github_oauth_without_allowlist_allowed_in_local(monkeypatch):
    """Local env keeps GitHub OAuth open-mode (empty allowlist) for dev convenience."""
    monkeypatch.setenv("APP_ENV", "local")
    monkeypatch.setenv("GITHUB_CLIENT_ID", "ghcid")
    monkeypatch.setenv("GITHUB_CLIENT_SECRET", "ghsecret")
    monkeypatch.setenv("PUBLIC_BASE_URL", "https://api.example.com")
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.mcp_oauth_enabled is True
    assert s.github_users_allowlist == set()


def test_mcp_unauth_allowed_in_local_without_github(monkeypatch):
    """`APP_ENV=local` permits MCP unauth without any GitHub OAuth config."""
    monkeypatch.setenv("APP_ENV", "local")
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.is_local_env is True
    assert s.mcp_oauth_enabled is False


def test_mcp_service_token_satisfies_prod_auth_requirement(monkeypatch):
    """A static `MCP_SERVICE_TOKEN` satisfies the prod auth requirement without GitHub OAuth."""
    monkeypatch.setenv("APP_ENV", "prod")
    monkeypatch.setenv("MCP_SERVICE_TOKEN", "x" * 32)
    monkeypatch.setenv("S3_ENDPOINT", "https://acc.r2.cloudflarestorage.com")
    monkeypatch.setenv("S3_BUCKET", "pulse-photos")
    monkeypatch.setenv("S3_ACCESS_KEY_ID", "ak")
    monkeypatch.setenv("S3_SECRET_ACCESS_KEY", "sk")
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.mcp_service_token_enabled is True
    assert s.mcp_oauth_enabled is False


def test_mcp_service_token_too_short_rejected(monkeypatch):
    """`MCP_SERVICE_TOKEN` shorter than the minimum is rejected at load time."""
    monkeypatch.setenv("APP_ENV", "local")
    monkeypatch.setenv("MCP_SERVICE_TOKEN", "short")
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    with pytest.raises(ValueError, match="at least"):
        cfg.get_settings()


def test_service_token_login_auto_included_in_allowlist(monkeypatch):
    """When the service token is set, its synthetic login joins `allowed_github_users_set`."""
    monkeypatch.setenv("APP_ENV", "prod")
    monkeypatch.setenv("MCP_SERVICE_TOKEN", "x" * 32)
    monkeypatch.setenv("ALLOWED_GITHUB_USERS", "khashazad")
    monkeypatch.setenv("S3_ENDPOINT", "https://acc.r2.cloudflarestorage.com")
    monkeypatch.setenv("S3_BUCKET", "pulse-photos")
    monkeypatch.setenv("S3_ACCESS_KEY_ID", "ak")
    monkeypatch.setenv("S3_SECRET_ACCESS_KEY", "sk")
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert cfg.SERVICE_TOKEN_LOGIN in s.allowed_github_users_set
    assert "khashazad" in s.allowed_github_users_set


def test_service_token_login_not_added_when_allowlist_empty(monkeypatch):
    """An empty `ALLOWED_GITHUB_USERS` stays empty (open mode) even with the service token set."""
    monkeypatch.setenv("APP_ENV", "prod")
    monkeypatch.setenv("MCP_SERVICE_TOKEN", "x" * 32)
    monkeypatch.setenv("S3_ENDPOINT", "https://acc.r2.cloudflarestorage.com")
    monkeypatch.setenv("S3_BUCKET", "pulse-photos")
    monkeypatch.setenv("S3_ACCESS_KEY_ID", "ak")
    monkeypatch.setenv("S3_SECRET_ACCESS_KEY", "sk")
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.allowed_github_users_set == set()


def test_s3_configured_requires_all_four_fields() -> None:
    """`s3_configured` is True only when endpoint, bucket, and both keys are set."""
    from pulse_server.config import Settings

    base = {"database_url": "postgresql://x/y", "usda_api_key": "k"}
    assert not Settings(**base).s3_configured
    assert not Settings(**base, s3_endpoint="https://acc.r2.cloudflarestorage.com").s3_configured
    assert not Settings(
        **base,
        s3_endpoint="https://acc.r2.cloudflarestorage.com",
        s3_bucket="pulse-photos",
        s3_access_key_id="ak",
    ).s3_configured
    assert not Settings(
        **base,
        s3_endpoint="https://acc.r2.cloudflarestorage.com",
        s3_bucket="pulse-photos",
    ).s3_configured
    assert Settings(
        **base,
        s3_endpoint="https://acc.r2.cloudflarestorage.com",
        s3_bucket="pulse-photos",
        s3_access_key_id="ak",
        s3_secret_access_key="sk",
    ).s3_configured


def test_non_local_env_requires_s3() -> None:
    """Non-local boots refuse to start without S3 config (photos would be unstorable)."""
    from pydantic import ValidationError

    from pulse_server.config import Settings

    base = {
        "database_url": "postgresql://x/y",
        "usda_api_key": "k",
        "app_env": "production",
        "mcp_service_token": "x" * 32,
    }
    with pytest.raises(ValidationError, match="S3"):
        Settings(**base)
    Settings(
        **base,
        s3_endpoint="https://acc.r2.cloudflarestorage.com",
        s3_bucket="pulse-photos",
        s3_access_key_id="ak",
        s3_secret_access_key="sk",
    )


_BASE_KWARGS = {"database_url": "postgresql://localhost/test", "usda_api_key": "x"}


def test_mcp_persistence_keys_default_empty():
    """Both persistence keys default to empty strings (feature off)."""
    from pulse_server.config import Settings

    settings = Settings(_env_file=None, **_BASE_KWARGS)
    assert settings.mcp_jwt_signing_key == ""
    assert settings.mcp_storage_encryption_key == ""


def test_mcp_storage_encryption_key_too_short_rejected():
    """A short MCP_STORAGE_ENCRYPTION_KEY is rejected at boot."""
    from pydantic import ValidationError

    from pulse_server.config import Settings

    with pytest.raises(ValidationError, match="MCP_STORAGE_ENCRYPTION_KEY"):
        Settings(_env_file=None, mcp_storage_encryption_key="short", **_BASE_KWARGS)


def test_mcp_jwt_signing_key_too_short_rejected():
    """A short MCP_JWT_SIGNING_KEY is rejected at boot."""
    from pydantic import ValidationError

    from pulse_server.config import Settings

    with pytest.raises(ValidationError, match="MCP_JWT_SIGNING_KEY"):
        Settings(_env_file=None, mcp_jwt_signing_key="short", **_BASE_KWARGS)


def test_mcp_persistence_keys_accept_strong_values():
    """32+ char values for both keys validate cleanly."""
    from pulse_server.config import Settings

    settings = Settings(
        _env_file=None,
        mcp_jwt_signing_key="j" * 40,
        mcp_storage_encryption_key="e" * 40,
        **_BASE_KWARGS,
    )
    assert settings.mcp_jwt_signing_key == "j" * 40
    assert settings.mcp_storage_encryption_key == "e" * 40


def test_mcp_persistence_keys_accept_exactly_min_length():
    """Exactly 32-char values are the shortest accepted (boundary)."""
    from pulse_server.config import Settings

    settings = Settings(
        _env_file=None,
        mcp_jwt_signing_key="j" * 32,
        mcp_storage_encryption_key="e" * 32,
        **_BASE_KWARGS,
    )
    assert settings.mcp_jwt_signing_key == "j" * 32
    assert settings.mcp_storage_encryption_key == "e" * 32
