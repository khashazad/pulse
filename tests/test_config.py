from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def _isolate_env(monkeypatch):
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
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert not hasattr(s, "api_key"), "api_key must be removed"


def test_settings_loads_oauth_envs():
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
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.allowed_emails_set == {"khashzd@gmail.com", "other@example.com"}


def test_redirect_uri_must_be_https_outside_local(monkeypatch):
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "http://api.example.com/auth/google/callback")
    monkeypatch.setenv("APP_ENV", "prod")
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    with pytest.raises(ValueError, match="must use https"):
        cfg.get_settings()


def test_redirect_uri_http_allowed_for_local(monkeypatch):
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "http://localhost:8787/auth/google/callback")
    monkeypatch.setenv("APP_ENV", "local")
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.oauth_redirect_uri.startswith("http://localhost")


def test_mcp_unauth_rejected_outside_local(monkeypatch):
    # Non-local env, no GitHub OAuth, no opt-in → must raise.
    monkeypatch.setenv("APP_ENV", "prod")
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    with pytest.raises(ValueError, match="MCP layer is unauthenticated"):
        cfg.get_settings()


def test_mcp_unauth_allowed_outside_local_with_explicit_optin(monkeypatch):
    monkeypatch.setenv("APP_ENV", "prod")
    monkeypatch.setenv("MCP_ALLOW_UNAUTH", "true")
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.mcp_allow_unauth is True
    assert s.mcp_oauth_enabled is False


def test_mcp_unauth_allowed_outside_local_with_github_oauth(monkeypatch):
    monkeypatch.setenv("APP_ENV", "prod")
    monkeypatch.setenv("GITHUB_CLIENT_ID", "ghcid")
    monkeypatch.setenv("GITHUB_CLIENT_SECRET", "ghsecret")
    monkeypatch.setenv("PUBLIC_BASE_URL", "https://api.example.com")
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.mcp_oauth_enabled is True


def test_mcp_unauth_allowed_in_local_without_github(monkeypatch):
    monkeypatch.setenv("APP_ENV", "local")
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.is_local_env is True
    assert s.mcp_oauth_enabled is False
