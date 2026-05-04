from __future__ import annotations

from fastmcp.exceptions import ToolError
from fastmcp.server.dependencies import get_access_token, get_http_headers
from fastmcp.server.middleware import Middleware, MiddlewareContext


class ApiKeyMiddleware(Middleware):
    """Validates `X-API-Key` (or `Authorization: Bearer <key>`) on every tool call.

    Used as the dev / non-OAuth fallback. Listing tools is unrestricted so MCP clients can
    introspect.
    """

    def __init__(self, configured_key: str) -> None:
        self._configured_key = configured_key

    async def on_call_tool(self, context: MiddlewareContext, call_next):
        headers = get_http_headers() or {}
        api_key = headers.get("x-api-key", "").strip()
        if not api_key:
            auth = headers.get("authorization", "").strip()
            if auth.lower().startswith("bearer "):
                api_key = auth[7:].strip()
        if not self._configured_key or api_key != self._configured_key:
            raise ToolError("Invalid API key")
        return await call_next(context)


class GitHubAllowlistMiddleware(Middleware):
    """Restricts tool calls to a whitelist of authenticated GitHub usernames.

    Runs after the OAuth provider validates the bearer token and populates the access token
    with GitHub claims. The username comes from the `login` claim that GitHubProvider stores
    after fetching `/user` from the GitHub API.
    """

    def __init__(self, allowed_logins: set[str]) -> None:
        self._allowed = {login.lower() for login in allowed_logins}

    async def on_call_tool(self, context: MiddlewareContext, call_next):
        if not self._allowed:
            return await call_next(context)
        token = get_access_token()
        if token is None:
            raise ToolError("Authentication required")
        login = (token.claims.get("login") or token.claims.get("username") or "").lower()
        if not login or login not in self._allowed:
            raise ToolError(f"GitHub user '{login or 'unknown'}' not in allowlist")
        return await call_next(context)
