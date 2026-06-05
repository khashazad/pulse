"""Tests for the MCP auth-provider assembly in `pulse_server.mcp.server`.

Covers `_build_auth_provider`'s four combinations (none / GitHub only /
service token only / both) and `_build_static_token_verifier`'s synthesized
GitHub-style claims used by `GitHubAllowlistMiddleware`.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

SERVICE_TOKEN = "s" * 40


@pytest.fixture(autouse=True)
def _isolate_env(monkeypatch):
    """Reset every MCP-auth-relevant env var so each test specifies its own config.

    **Inputs:**
    - monkeypatch (pytest.MonkeyPatch): Used to manage env var state.
    """
    for k in (
        "APP_ENV",
        "GITHUB_CLIENT_ID",
        "GITHUB_CLIENT_SECRET",
        "PUBLIC_BASE_URL",
        "ALLOWED_GITHUB_USERS",
        "MCP_ALLOW_UNAUTH",
        "MCP_SERVICE_TOKEN",
    ):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("DATABASE_URL", "postgresql://localhost/test")
    monkeypatch.setenv("USDA_API_KEY", "x")
    monkeypatch.setenv("APP_ENV", "local")
    yield


def _reload_settings():
    from pulse_server import config as cfg

    cfg.get_settings.cache_clear()
    return cfg.get_settings()


@pytest.mark.asyncio
async def test_static_verifier_accepts_token_and_carries_login_claim():
    """The static verifier resolves the configured token and emits the synthetic login claim."""
    from pulse_server.config import SERVICE_TOKEN_LOGIN
    from pulse_server.mcp.server import _build_static_token_verifier

    verifier = _build_static_token_verifier(SERVICE_TOKEN)
    access = await verifier.verify_token(SERVICE_TOKEN)
    assert access is not None
    assert access.claims.get("login") == SERVICE_TOKEN_LOGIN
    assert await verifier.verify_token("not-the-token") is None


def test_build_auth_provider_returns_none_when_nothing_configured():
    """No GitHub OAuth and no service token → no auth provider; caller decides fallback."""
    from pulse_server.mcp.server import _build_auth_provider

    settings = _reload_settings()
    assert _build_auth_provider(settings) is None


def test_build_auth_provider_uses_static_verifier_when_only_service_token_set(monkeypatch):
    """Service token alone → bare `StaticTokenVerifier`; no GitHub OAuth routes."""
    from fastmcp.server.auth.providers.jwt import StaticTokenVerifier

    monkeypatch.setenv("MCP_SERVICE_TOKEN", SERVICE_TOKEN)
    from pulse_server.mcp.server import _build_auth_provider

    provider = _build_auth_provider(_reload_settings())
    assert isinstance(provider, StaticTokenVerifier)


def test_build_auth_provider_wraps_in_multiauth_when_both_configured(monkeypatch):
    """GitHub OAuth + service token → `MultiAuth` with GitHub as server and static as verifier."""
    from fastmcp.server.auth import MultiAuth
    from fastmcp.server.auth.providers.github import GitHubProvider
    from fastmcp.server.auth.providers.jwt import StaticTokenVerifier

    monkeypatch.setenv("GITHUB_CLIENT_ID", "ghcid")
    monkeypatch.setenv("GITHUB_CLIENT_SECRET", "ghsecret")
    monkeypatch.setenv("PUBLIC_BASE_URL", "https://api.example.com")
    monkeypatch.setenv("MCP_SERVICE_TOKEN", SERVICE_TOKEN)

    from pulse_server.mcp.server import _build_auth_provider

    provider = _build_auth_provider(_reload_settings())
    assert isinstance(provider, MultiAuth)
    assert isinstance(provider.server, GitHubProvider)
    assert len(provider.verifiers) == 1
    assert isinstance(provider.verifiers[0], StaticTokenVerifier)


def test_build_auth_provider_uses_github_only_when_no_service_token(monkeypatch):
    """GitHub OAuth alone → bare `GitHubProvider`; no `MultiAuth` wrapping."""
    from fastmcp.server.auth.providers.github import GitHubProvider

    monkeypatch.setenv("GITHUB_CLIENT_ID", "ghcid")
    monkeypatch.setenv("GITHUB_CLIENT_SECRET", "ghsecret")
    monkeypatch.setenv("PUBLIC_BASE_URL", "https://api.example.com")

    from pulse_server.mcp.server import _build_auth_provider

    provider = _build_auth_provider(_reload_settings())
    assert isinstance(provider, GitHubProvider)


@pytest.mark.asyncio
async def test_build_mcp_accepts_service_token_in_prod(monkeypatch):
    """`build_mcp` boots in prod with only a service token and exposes the full tool surface."""
    monkeypatch.setenv("APP_ENV", "prod")
    monkeypatch.setenv("MCP_SERVICE_TOKEN", SERVICE_TOKEN)
    _reload_settings()

    from pulse_server.mcp import build_mcp

    mcp = build_mcp(lambda: MagicMock())
    tools = await mcp.list_tools()
    assert any(t.name == "log_food" for t in tools)


def _token(login: str | None):
    """Build a fake access token whose claims carry the given GitHub login.

    **Inputs:**
    - login (str | None): GitHub login to place in the ``login`` claim, or
      ``None`` to omit it.

    **Outputs:**
    - MagicMock: An object exposing ``.claims`` like a FastMCP access token.
    """
    tok = MagicMock()
    tok.claims = {"login": login} if login is not None else {}
    return tok


@pytest.mark.asyncio
async def test_allowlist_middleware_open_mode_passes_through():
    """An empty allowlist lets every tool call through without checking a token."""
    from pulse_server.mcp.auth import GitHubAllowlistMiddleware

    mw = GitHubAllowlistMiddleware(set())
    ctx = MagicMock()

    async def call_next(received_ctx):
        assert received_ctx is ctx
        return "ok"

    assert await mw.on_call_tool(ctx, call_next) == "ok"


@pytest.mark.asyncio
async def test_allowlist_middleware_allows_listed_login(monkeypatch):
    """A token whose `login` is in the allowlist (case-insensitive) is allowed."""
    from pulse_server.mcp import auth as auth_module
    from pulse_server.mcp.auth import GitHubAllowlistMiddleware

    monkeypatch.setattr(auth_module, "get_access_token", lambda: _token("OctoCat"))
    mw = GitHubAllowlistMiddleware({"octocat"})

    async def call_next(_ctx):
        return "allowed"

    assert await mw.on_call_tool(MagicMock(), call_next) == "allowed"


@pytest.mark.asyncio
async def test_allowlist_middleware_rejects_unlisted_login(monkeypatch):
    """A token whose `login` is not in the allowlist raises a ToolError."""
    from fastmcp.exceptions import ToolError

    from pulse_server.mcp import auth as auth_module
    from pulse_server.mcp.auth import GitHubAllowlistMiddleware

    monkeypatch.setattr(auth_module, "get_access_token", lambda: _token("intruder"))
    mw = GitHubAllowlistMiddleware({"octocat"})

    async def call_next(_ctx):  # pragma: no cover - must not be reached
        return "should not run"

    with pytest.raises(ToolError):
        await mw.on_call_tool(MagicMock(), call_next)


@pytest.mark.asyncio
async def test_allowlist_middleware_rejects_when_no_token(monkeypatch):
    """A configured allowlist with no access token available raises a ToolError."""
    from fastmcp.exceptions import ToolError

    from pulse_server.mcp import auth as auth_module
    from pulse_server.mcp.auth import GitHubAllowlistMiddleware

    monkeypatch.setattr(auth_module, "get_access_token", lambda: None)
    mw = GitHubAllowlistMiddleware({"octocat"})

    async def call_next(_ctx):  # pragma: no cover - must not be reached
        return "should not run"

    with pytest.raises(ToolError):
        await mw.on_call_tool(MagicMock(), call_next)
