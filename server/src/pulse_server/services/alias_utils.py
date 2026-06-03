"""Shared alias-normalization and collision-detection helpers.

Both the meals and food-memory write paths normalize user-supplied aliases
and pre-check them against existing rows the same way; they differ only in the
table/column they probe. This module houses the single ``normalize_alias_list``
and a parameterized ``assert_alias_available`` that those feature-specific
``assert_*`` wrappers delegate to.
"""

from __future__ import annotations

from typing import Any

from sqlalchemy import Column, Table, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.services.normalize import normalize_name


def normalize_alias_list(aliases: list[str], canonical_normalized_name: str) -> list[str]:
    """Normalize aliases, drop empties, dedupe, and drop the alias equal to the canonical name.

    **Inputs:**
    - aliases (list[str]): Raw, user-supplied alias strings.
    - canonical_normalized_name (str): Already-normalized canonical name;
      an alias equal to this value is discarded.

    **Outputs:**
    - list[str]: Order-preserving list of normalized, unique aliases that do
      not collide with the canonical name.
    """
    seen: set[str] = set()
    out: list[str] = []
    for raw in aliases:
        norm = normalize_name(raw)
        if not norm or norm == canonical_normalized_name or norm in seen:
            continue
        seen.add(norm)
        out.append(norm)
    return out


async def assert_alias_available(
    session: AsyncSession,
    *,
    table: Table,
    name_column: Column[Any],
    aliases_column: Column[Any],
    user_key: str,
    alias: str,
    exclude_value: Any,
    exclude_column: Column[Any] | None,
    entity_label: str,
) -> None:
    """Verify an alias is not already used as a canonical name or alias on another row.

    Parameterized over the table and columns so both the meals and food-memory
    collision checks share one query body.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session.
    - table (Table): Table to probe for collisions.
    - name_column (Column[Any]): Column holding the canonical normalized name.
    - aliases_column (Column[Any]): Array column holding existing aliases.
    - user_key (str): Owning user's scoping key.
    - alias (str): Normalized alias to check.
    - exclude_value (Any): Value identifying the row to exclude (the row being
      edited); ignored when ``None``.
    - exclude_column (Column[Any] | None): Column compared against
      ``exclude_value`` to exclude the edited row.
    - entity_label (str): Human-readable entity name embedded in the error
      message (e.g. ``"meal"``).

    **Outputs:**
    - None: Returns nothing when no collision is found.

    **Raises:**
    - ValueError: Raised when ``alias`` collides with another row.
    - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    """
    stmt = (
        select(name_column)
        .where(table.c.user_key == user_key)
        .where(
            or_(
                name_column == alias,
                aliases_column.any(alias),
            )
        )
    )
    if exclude_value is not None and exclude_column is not None:
        stmt = stmt.where(exclude_column != exclude_value)
    result = await session.execute(stmt)
    existing = result.scalar_one_or_none()
    if existing is not None:
        raise ValueError(
            f"alias '{alias}' is already used by {entity_label} '{existing}'"
        )
