"""Custom-food write-path business logic.

Provides :func:`upsert_custom_food_and_remember`, which couples a custom-food
upsert with a corresponding ``food_memory`` pointer so that the next time the
user mentions the same name it resolves directly to this custom food. The
function composes :class:`CustomFoodsRepository` and
:class:`FoodMemoryRepository` and assumes the caller controls the transaction
boundary.
"""

from __future__ import annotations

from collections.abc import Iterable
from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.models import CustomFoodCreate
from pulse_server.repositories.custom_foods import CustomFoodsRepository
from pulse_server.repositories.food_memory import FoodMemoryRepository
from pulse_server.services.normalize import normalize_name


class CrossTenantReferenceError(ValueError):
    """Raised when a request references a ``custom_food_id`` the user does not own.

    The ``custom_foods`` foreign keys only prove the referenced UUID exists, not
    that it belongs to the requesting user. Callers map this to a client error
    (HTTP 422 / MCP ``ToolError``) so a user cannot create cross-tenant
    references to another user's custom food.
    """


async def assert_custom_foods_owned(
    session: AsyncSession,
    user_key: str,
    custom_food_ids: Iterable[UUID | None],
) -> None:
    """Verify every supplied ``custom_food_id`` is owned by ``user_key``.

    ``None`` entries are ignored (an item may instead reference USDA), and each
    distinct id is checked once.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session.
    - user_key (str): Owning user's scoping key.
    - custom_food_ids (Iterable[UUID | None]): Candidate ids drawn from a
      request payload; ``None`` values are skipped.

    **Outputs:**
    - None: Returns nothing when every non-null id is owned by the user.

    **Raises:**
    - CrossTenantReferenceError: When any id does not exist or is owned by a
      different user.
    - sqlalchemy.exc.SQLAlchemyError: When SQL execution fails.
    """
    repo = CustomFoodsRepository(session)
    checked: set[UUID] = set()
    for cfid in custom_food_ids:
        if cfid is None or cfid in checked:
            continue
        checked.add(cfid)
        if await repo.get_by_id(cfid, user_key) is None:
            raise CrossTenantReferenceError(
                f"custom_food_id {cfid} does not exist or is not owned by this user"
            )


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
