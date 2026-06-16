"""Food-memory resolution and alias-management logic.

Resolves free-text food phrases against the user's per-row ``food_memory``
table (which may point either at a USDA food or a user-defined custom food),
materializing the macros and basis needed to scale and log. Also exposes
alias normalization and collision-detection helpers used by the food-memory
write paths.
"""

from __future__ import annotations

from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.models import CustomFoodResponse, ResolvedFood
from pulse_server.models.adapters import custom_food_response, food_portion
from pulse_server.repositories.custom_foods import CustomFoodsRepository
from pulse_server.repositories.food_memory import FoodMemoryRepository
from pulse_server.repositories.foods import FoodsRepository
from pulse_server.repositories.tables import food_memory
from pulse_server.services.alias_utils import assert_alias_available
from pulse_server.services.normalize import normalize_name, optional_float


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
    - ResolvedFood: ``type`` is ``"none"`` when no memory entry exists or
      when the referenced Food no longer exists in the database; ``"memory_usda"``
      or ``"custom_food"`` with all fields needed to scale macros and call
      ``log_food``; or ``"food"`` when the entry targets a grouped Food — in
      that case ``portions`` lists every :class:`FoodPortion` (each with its
      own ``custom_food_id`` and per-portion macros), ``default_portion_id``
      identifies the suggested starting selection, and the caller picks a
      portion, scales it, and logs with that portion's ``custom_food_id``.

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
            serving_size=optional_float(row["cf_serving_size"]),
            serving_size_unit=row["cf_serving_size_unit"],
            calories=int(row["cf_calories"]),
            protein_g=float(row["cf_protein_g"]),
            carbs_g=float(row["cf_carbs_g"]),
            fat_g=float(row["cf_fat_g"]),
        )

    if row["food_id"] is not None:
        foods_repo = FoodsRepository(session)
        cf_repo = CustomFoodsRepository(session)
        food = await foods_repo.get_by_id(row["food_id"], user_key)
        if food is None:
            return ResolvedFood(type="none")
        portion_rows = await cf_repo.list_by_food(row["food_id"], user_key)
        if not portion_rows:
            # A Food whose portions were all detached has nothing loggable;
            # resolve to a graceful miss so the caller falls through to search
            # rather than receiving a type="food" result it cannot act on.
            return ResolvedFood(type="none")
        return ResolvedFood(
            type="food",
            name=row["name"],
            food_id=row["food_id"],
            default_portion_id=food["default_portion_id"],
            portions=[food_portion(p) for p in portion_rows],
        )

    return ResolvedFood(
        type="memory_usda",
        name=row["name"],
        usda_fdc_id=int(row["usda_fdc_id"]),
        usda_description=row["usda_description"],
        basis=row["basis"],
        serving_size=optional_float(row["serving_size"]),
        serving_size_unit=row["serving_size_unit"],
        calories=int(row["calories"]),
        protein_g=float(row["protein_g"]),
        carbs_g=float(row["carbs_g"]),
        fat_g=float(row["fat_g"]),
    )


def _custom_food_from_row(row: dict[str, Any]) -> CustomFoodResponse:
    """Project the joined ``cf_*`` columns of a memory row into the custom-food DTO.

    **Inputs:**
    - row (dict[str, Any]): Joined memory+custom-food row keyed by the
      ``cf_<column>`` aliases used in the join.

    **Outputs:**
    - CustomFoodResponse: Wire DTO built from the projected ``cf_*`` columns
      via the shared :func:`custom_food_response` adapter.
    """
    return custom_food_response(
        {
            "id": row["cf_id"],
            "user_key": row["cf_user_key"],
            "name": row["cf_name"],
            "normalized_name": row["cf_normalized_name"],
            "basis": row["cf_basis"],
            "serving_size": optional_float(row["cf_serving_size"]),
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
    )


async def assert_food_alias_available(
    session: AsyncSession,
    user_key: str,
    alias: str,
    exclude_normalized_name: str | None,
) -> None:
    """Verify an alias is not already used as a canonical name or alias on another row.

    Thin wrapper over :func:`assert_alias_available` bound to the
    ``food_memory`` table.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session.
    - user_key (str): Owning user's scoping key.
    - alias (str): Normalized alias to check.
    - exclude_normalized_name (str | None): Canonical name to exclude from
      the check (the row being edited).

    **Outputs:**
    - None: Returns nothing when no collision is found.

    **Raises:**
    - ValueError: Raised when ``alias`` collides with another memory row.
    - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    """
    await assert_alias_available(
        session,
        table=food_memory,
        name_column=food_memory.c.normalized_name,
        aliases_column=food_memory.c.aliases,
        user_key=user_key,
        alias=alias,
        exclude_value=exclude_normalized_name,
        exclude_column=food_memory.c.normalized_name,
        entity_label="food memory entry",
    )
