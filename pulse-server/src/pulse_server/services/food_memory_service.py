"""Food-memory resolution and alias-management logic.

Resolves free-text food phrases against the user's per-row ``food_memory``
table (which may point either at a USDA food or a user-defined custom food),
materializing the macros and basis needed to scale and log. Also exposes
alias normalization and collision-detection helpers used by the food-memory
write paths.
"""

from __future__ import annotations

from typing import Any

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.models import ResolvedFood
from pulse_server.repositories.food_memory import FoodMemoryRepository
from pulse_server.repositories.tables import food_memory
from pulse_server.services.normalize import normalize_name


async def resolve_food_by_name(
    session: AsyncSession,
    user_key: str,
    name: str,
) -> ResolvedFood:
    """Resolve a free-text food name against the user's memory table.

    Normalizes the name and queries ``food_memory``; returns a discriminated
    :class:`ResolvedFood` carrying every field the caller needs to scale
    macros and call ``log_food`` without further lookups.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session.
    - user_key (str): Owning user's scoping key.
    - name (str): User-supplied food phrase.

    **Outputs:**
    - ResolvedFood: ``type`` is ``"none"`` when no memory entry exists;
      otherwise ``"memory_usda"`` or ``"custom_food"`` with all fields
      needed to scale macros and call ``log_food``.

    **Exceptions:**
    - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    """
    repo = FoodMemoryRepository(session)
    row = await repo.get_by_name(user_key=user_key, normalized_name=normalize_name(name))
    if row is None:
        return ResolvedFood(type="none")

    if row["custom_food_id"] is not None:
        return ResolvedFood(
            type="custom_food",
            name=row["name"],
            custom_food_id=row["custom_food_id"],
            custom_food=_custom_food_from_row(row),
            basis=row["cf_basis"],
            serving_size=_optional_float(row["cf_serving_size"]),
            serving_size_unit=row["cf_serving_size_unit"],
            calories=int(row["cf_calories"]),
            protein_g=float(row["cf_protein_g"]),
            carbs_g=float(row["cf_carbs_g"]),
            fat_g=float(row["cf_fat_g"]),
        )

    return ResolvedFood(
        type="memory_usda",
        name=row["name"],
        usda_fdc_id=int(row["usda_fdc_id"]),
        usda_description=row["usda_description"],
        basis=row["basis"],
        serving_size=_optional_float(row["serving_size"]),
        serving_size_unit=row["serving_size_unit"],
        calories=int(row["calories"]),
        protein_g=float(row["protein_g"]),
        carbs_g=float(row["carbs_g"]),
        fat_g=float(row["fat_g"]),
    )


def _optional_float(value: Any) -> float | None:
    """Coerce a possibly-``None`` numeric value to ``float | None``.

    **Inputs:**
    - value (Any): Numeric value or ``None``.

    **Outputs:**
    - float | None: ``None`` when input is ``None``, otherwise ``float(value)``.
    """
    return None if value is None else float(value)


def _custom_food_from_row(row: dict[str, Any]) -> dict[str, Any]:
    """Project the joined ``cf_*`` columns of a memory row back into a custom-food dict.

    **Inputs:**
    - row (dict[str, Any]): Joined memory+custom-food row keyed by the
      ``cf_<column>`` aliases used in the join.

    **Outputs:**
    - dict[str, Any]: Custom-food fields shaped like the bare custom_foods
      row (``id``, ``user_key``, ``name``, ``basis``, macros, timestamps).
    """
    return {
        "id": row["cf_id"],
        "user_key": row["cf_user_key"],
        "name": row["cf_name"],
        "normalized_name": row["cf_normalized_name"],
        "basis": row["cf_basis"],
        "serving_size": _optional_float(row["cf_serving_size"]),
        "serving_size_unit": row["cf_serving_size_unit"],
        "calories": int(row["cf_calories"]),
        "protein_g": float(row["cf_protein_g"]),
        "carbs_g": float(row["cf_carbs_g"]),
        "fat_g": float(row["cf_fat_g"]),
        "source": row["cf_source"],
        "notes": row["cf_notes"],
        "created_at": row["cf_created_at"],
        "updated_at": row["cf_updated_at"],
    }


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


async def assert_food_alias_available(
    session: AsyncSession,
    user_key: str,
    alias: str,
    exclude_normalized_name: str | None,
) -> None:
    """Verify an alias is not already used as a canonical name or alias on another row.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session.
    - user_key (str): Owning user's scoping key.
    - alias (str): Normalized alias to check.
    - exclude_normalized_name (str | None): Canonical name to exclude from
      the check (the row being edited).

    **Exceptions:**
    - ValueError: Raised when ``alias`` collides with another memory row.
    - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    """
    stmt = (
        select(food_memory.c.normalized_name)
        .where(food_memory.c.user_key == user_key)
        .where(
            or_(
                food_memory.c.normalized_name == alias,
                food_memory.c.aliases.any(alias),
            )
        )
    )
    if exclude_normalized_name is not None:
        stmt = stmt.where(food_memory.c.normalized_name != exclude_normalized_name)
    result = await session.execute(stmt)
    existing = result.scalar_one_or_none()
    if existing is not None:
        raise ValueError(
            f"alias '{alias}' is already used by food memory entry '{existing}'"
        )
