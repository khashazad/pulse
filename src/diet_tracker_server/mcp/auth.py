"""GitHub-allowlist authentication middleware for the MCP server.

Defines :class:`GitHubAllowlistMiddleware`, a FastMCP middleware that rejects
tool calls from GitHub users outside a configured allowlist. It runs after
``GitHubProvider`` has validated the OAuth bearer token and populated the access
token with GitHub claims (notably ``login``).

This module is the MCP layer's authorization gate, sitting alongside
``server.py``'s OAuth bootstrap; only allowlisted GitHub identities reach the
diet-tracking tools.
"""

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
        """Build the middleware with a case-insensitive allowlist.

        **Inputs:**
        - allowed_logins (set[str]): GitHub usernames permitted to invoke tools;
          stored lowercased for case-insensitive comparison.
        """
        self._allowed = {login.lower() for login in allowed_logins}

    async def on_call_tool(self, context: MiddlewareContext, call_next):
        """Gate a tool invocation on the caller's GitHub ``login`` claim.

        When the allowlist is empty the call passes through unchanged
        (open-mode). Otherwise the current access token must carry a ``login``
        (or ``username``) claim matching an allowlisted user.

        **Inputs:**
        - context (MiddlewareContext): FastMCP middleware context for this tool call.
        - call_next: Callable that continues middleware chain execution.

        **Outputs:**
        - The downstream tool invocation's result when authorization succeeds.

        **Exceptions:**
        - ToolError: No access token is available, or the token's GitHub login
          is missing/not in the allowlist.
        """
        if not self._allowed:
            return await call_next(context)
        token = get_access_token()
        if token is None:
            raise ToolError("Authentication required")
        login = (token.claims.get("login") or token.claims.get("username") or "").lower()
        if not login or login not in self._allowed:
            raise ToolError(f"GitHub user '{login or 'unknown'}' not in allowlist")
        return await call_next(context)
