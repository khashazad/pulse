"""Unit tests for `diet_tracker_server.config.Settings`.

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
        "PUBLIC_BASE_URL",
        "MCP_ALLOW_UNAUTH",
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
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert not hasattr(s, "api_key"), "api_key must be removed"


def test_settings_loads_oauth_envs():
    """`Settings` populates Google OAuth fields and TTL defaults from env."""
    from diet_tracker_server import config as cfg

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
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.allowed_emails_set == {"khashzd@gmail.com", "other@example.com"}


def test_redirect_uri_must_be_https_outside_local(monkeypatch):
    """Non-HTTPS `OAUTH_REDIRECT_URI` outside `APP_ENV=local` raises `ValueError`."""
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "http://api.example.com/auth/google/callback")
    monkeypatch.setenv("APP_ENV", "prod")
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    with pytest.raises(ValueError, match="must use https"):
        cfg.get_settings()


def test_redirect_uri_http_allowed_for_local(monkeypatch):
    """`http://localhost` redirect URIs are accepted when `APP_ENV=local`."""
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "http://localhost:8787/auth/google/callback")
    monkeypatch.setenv("APP_ENV", "local")
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.oauth_redirect_uri.startswith("http://localhost")


def test_mcp_unauth_rejected_outside_local(monkeypatch):
    """Non-local env with no GitHub OAuth and no `MCP_ALLOW_UNAUTH` opt-in raises."""
    # Non-local env, no GitHub OAuth, no opt-in → must raise.
    monkeypatch.setenv("APP_ENV", "prod")
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    with pytest.raises(ValueError, match="MCP layer is unauthenticated"):
        cfg.get_settings()


def test_mcp_unauth_allowed_outside_local_with_explicit_optin(monkeypatch):
    """Explicit `MCP_ALLOW_UNAUTH=true` permits MCP unauth outside `local` without GitHub OAuth."""
    monkeypatch.setenv("APP_ENV", "prod")
    monkeypatch.setenv("MCP_ALLOW_UNAUTH", "true")
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.mcp_allow_unauth is True
    assert s.mcp_oauth_enabled is False


def test_mcp_unauth_allowed_outside_local_with_github_oauth(monkeypatch):
    """Configuring GitHub OAuth in prod enables MCP OAuth and clears the unauth gate."""
    monkeypatch.setenv("APP_ENV", "prod")
    monkeypatch.setenv("GITHUB_CLIENT_ID", "ghcid")
    monkeypatch.setenv("GITHUB_CLIENT_SECRET", "ghsecret")
    monkeypatch.setenv("PUBLIC_BASE_URL", "https://api.example.com")
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.mcp_oauth_enabled is True


def test_mcp_unauth_allowed_in_local_without_github(monkeypatch):
    """`APP_ENV=local` permits MCP unauth without any GitHub OAuth config."""
    monkeypatch.setenv("APP_ENV", "local")
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.is_local_env is True
    assert s.mcp_oauth_enabled is False
