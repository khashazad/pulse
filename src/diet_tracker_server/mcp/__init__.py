"""MCP (Model Context Protocol) integration package.

Re-exports :func:`build_mcp`, the factory used by ``app.py`` to construct the
FastMCP server that exposes diet-tracking tools to MCP clients (claude.ai
connector, local CLI, etc.). The package houses the MCP server definition
(``server.py``) and its GitHub-allowlist authentication middleware (``auth.py``);
this module is the single import surface for the rest of the codebase.
"""

from diet_tracker_server.mcp.server import build_mcp

__all__ = ["build_mcp"]
