"""MCP tools for meal-prep containers (tare-weight presets).

Registers ``list_containers``, ``save_container``, ``update_container``, and
``delete_container``. Responses are built via the shared
:func:`container_response` adapter so MCP and REST emit one shape.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import Field
from sqlalchemy.exc import IntegrityError

from pulse_server.db import get_session, transaction
from pulse_server.mcp.context import ToolContext
from pulse_server.models import ContainerResponse, container_response
from pulse_server.repositories.containers import ContainersRepository
from pulse_server.services.normalize import normalize_name


def register(mcp: FastMCP, ctx: ToolContext) -> None:
    """Register the container CRUD tools on the MCP server.

    **Inputs:**
    - mcp (FastMCP): The server to attach the tool closures to.
    - ctx (ToolContext): Shared context carrying ``user_key`` and ``tz``.

    **Outputs:**
    - None: Tools are registered as a side effect.
    """
    user_key = ctx.user_key
    tz = ctx.tz

    @mcp.tool
    async def list_containers() -> list[ContainerResponse]:
        """List all meal-prep containers (pots, boxes) saved for this user. Each row
        carries `tare_weight_g`, the container's empty weight in grams, used to deduct
        from a scale reading when meal-prepping."""
        async with get_session() as session:
            repo = ContainersRepository(session)
            rows = await repo.list_for_user(user_key)
        return [container_response(r) for r in rows]

    @mcp.tool
    async def save_container(
        name: str,
        tare_weight_g: float = Field(gt=0),
    ) -> ContainerResponse:
        """Create a new meal-prep container with its empty (tare) weight in grams.
        Use this when the user mentions a new pot/box they want to track."""
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = ContainersRepository(session)
            try:
                async with transaction(session):
                    row = await repo.create(
                        user_key=user_key,
                        name=name,
                        normalized_name=normalize_name(name),
                        tare_weight_g=tare_weight_g,
                        now=now,
                    )
            except IntegrityError as exc:
                raise ToolError("A container with that name already exists") from exc
        return container_response(row)

    @mcp.tool
    async def update_container(
        container_id: str,
        name: str | None = None,
        tare_weight_g: float | None = Field(default=None, gt=0),
    ) -> ContainerResponse:
        """Update name and/or tare weight of an existing container."""
        try:
            cid = UUID(container_id)
        except ValueError as exc:
            raise ToolError("container_id must be a UUID") from exc
        fields: dict[str, Any] = {}
        if name is not None:
            fields["name"] = name
            fields["normalized_name"] = normalize_name(name)
        if tare_weight_g is not None:
            fields["tare_weight_g"] = tare_weight_g
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = ContainersRepository(session)
            try:
                async with transaction(session):
                    row = await repo.update_fields(cid, user_key, fields, now)
            except IntegrityError as exc:
                raise ToolError("A container with that name already exists") from exc
        if row is None:
            raise ToolError("Container not found")
        return container_response(row)

    @mcp.tool
    async def delete_container(container_id: str) -> dict[str, bool]:
        """Delete a container by id."""
        try:
            cid = UUID(container_id)
        except ValueError as exc:
            raise ToolError("container_id must be a UUID") from exc
        async with get_session() as session:
            repo = ContainersRepository(session)
            async with transaction(session):
                deleted = await repo.delete(cid, user_key)
        return {"deleted": deleted}
