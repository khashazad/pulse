"""Custom-food write-path business logic.

Provides :func:`upsert_custom_food_and_remember`, which couples a custom-food
upsert with a corresponding ``food_memory`` pointer so that the next time the
user mentions the same name it resolves directly to this custom food. The
function composes :class:`CustomFoodsRepository` and
:class:`FoodMemoryRepository` and assumes the caller controls the transaction
boundary.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.models import CustomFoodCreate
from pulse_server.repositories.custom_foods import CustomFoodsRepository
from pulse_server.repositories.food_memory import FoodMemoryRepository
from pulse_server.services.normalize import normalize_name


async def upsert_custom_food_and_remember(
    session: AsyncSession,
    user_key: str,
    payload: CustomFoodCreate,
    now: DateTimeValue,
) -> dict[str, Any]:
    """Upsert a custom food and write its ``food_memory`` pointer in one pass.

    Both writes share the caller's session; transaction management is the
    caller's responsibility.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session.
    - user_key (str): Owning user's scoping key.
    - payload (CustomFoodCreate): Custom-food fields supplied by the caller.
    - now (DateTimeValue): Timestamp stamped on the row's mtime and the
      memory pointer.

    **Outputs:**
    - dict[str, Any]: The upserted custom-food row as a column→value mapping.

    **Exceptions:**
    - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails; the
      caller controls the transaction.
    """
    foods_repo = CustomFoodsRepository(session)
    memory_repo = FoodMemoryRepository(session)
    normalized = normalize_name(payload.name)

    food_row = await foods_repo.upsert(
        user_key=user_key,
        name=payload.name,
        normalized_name=normalized,
        basis=payload.basis,
        serving_size=payload.serving_size,
        serving_size_unit=payload.serving_size_unit,
        calories=payload.calories,
        protein_g=payload.protein_g,
        carbs_g=payload.carbs_g,
        fat_g=payload.fat_g,
        source=payload.source,
        notes=payload.notes,
        now=now,
    )
    await memory_repo.upsert_custom(
        user_key=user_key,
        name=payload.name,
        normalized_name=normalized,
        custom_food_id=food_row["id"],
        now=now,
    )
    return food_row
