from __future__ import annotations

from fastmcp.exceptions import ToolError
from fastmcp.server.dependencies import get_access_token
from fastmcp.server.middleware import Middleware, MiddlewareContext


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
