"""MCP tool registration modules.

Each module in this package exposes a ``register(mcp, ctx)`` function that
defines and attaches one feature group's ``@mcp.tool`` closures to the FastMCP
server, closing over a shared :class:`pulse_server.mcp.context.ToolContext`.
``pulse_server.mcp.server.build_mcp`` calls every group's ``register`` in turn.
"""
