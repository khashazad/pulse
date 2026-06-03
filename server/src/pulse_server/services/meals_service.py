"""Meals service: create saved meals and expand them into food entries.

Owns the two write paths that touch the ``meals`` and ``meal_items`` tables
plus the read-and-expand flow that turns a saved meal into a batch of
food entries (``log_meal``). Composes :class:`MealsRepository`,
:func:`create_entries_with_side_effects`, and the alias-normalization helpers.
Each saved meal pre-scales macros at create time so logging is a pure
fan-out (no rescaling).
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.db import transaction
from pulse_server.models import (
    FoodEntryCreate,
    MealCreate,
    MealItemCreate,
)
from pulse_server.repositories.meals import MealsRepository
from pulse_server.repositories.tables import meals as meals_table
from pulse_server.services.alias_utils import (
    assert_alias_available,
    normalize_alias_list,
)
from pulse_server.services.custom_foods_service import (
    CrossTenantReferenceError,
    assert_custom_foods_owned,
)
from pulse_server.services.entries_service import create_entries_with_side_effects
from pulse_server.services.normalize import normalize_name
from pulse_server.services.normalize import optional_float


def _validate_item_source(item: MealItemCreate) -> None:
    """Validate that a meal item references exactly one food source (USDA xor custom).

    **Inputs:**
    - item (MealItemCreate): Caller-supplied item payload.

    **Exceptions:**
    - fastapi.HTTPException: Raised with 422 when both or neither sources
      are provided, or when ``usda_fdc_id`` is set without
      ``usda_description``.
    """
    has_usda = item.usda_fdc_id is not None
    has_custom = item.custom_food_id is not None
    if has_usda == has_custom:
        raise HTTPException(
            status_code=422,
            detail="Each meal item must specify exactly one of usda_fdc_id or custom_food_id",
        )
    if has_usda and not item.usda_description:
        raise HTTPException(
            status_code=422,
            detail="usda_description is required when usda_fdc_id is set",
        )


async def create_meal_with_items(
    session: AsyncSession,
    user_key: str,
    payload: MealCreate,
    now: DateTimeValue,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Create a meal with its items in one transaction; macros are pre-scaled at create time.

    Validates each item's source, pre-checks alias collisions (mapped to
    409), then inserts the meal row and its items in declaration order.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session (caller controls
      the transaction boundary).
    - user_key (str): Owning user's scoping key.
    - payload (MealCreate): Meal definition with items.
    - now (DateTimeValue): Timestamp stamped on the inserted rows.

    **Outputs:**
    - tuple[dict[str, Any], list[dict[str, Any]]]: Created meal row and its
      inserted item rows in position order.

    **Exceptions:**
    - fastapi.HTTPException: Raised with 422 when an item violates the
      exactly-one-of rule or references a custom_food_id the user does not
      own, or with 409 when an alias collides with an existing meal
      name/alias.
    - sqlalchemy.exc.IntegrityError: Raised on duplicate
      ``(user_key, normalized_name)`` meal name.
    """
    repo = MealsRepository(session)
    for item in payload.items:
        _validate_item_source(item)

    # Custom-food references must belong to this user; the meal_items FK only
    # proves the UUID exists, not its owner.
    try:
        await assert_custom_foods_owned(
            session, user_key, (item.custom_food_id for item in payload.items)
        )
    except CrossTenantReferenceError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    normalized_aliases = normalize_alias_list(
        list(payload.aliases),
        canonical_normalized_name=normalize_name(payload.name),
    )
    # Validate each alias against existing meals (collision pre-check)
    for a in normalized_aliases:
        try:
            await assert_meal_alias_available(
                session=session, user_key=user_key, alias=a, exclude_meal_id=None,
            )
        except ValueError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    meal_row = await repo.create_meal(
        user_key=user_key,
        name=payload.name,
        normalized_name=normalize_name(payload.name),
        notes=payload.notes,
        now=now,
        aliases=normalized_aliases if normalized_aliases else None,
    )
    item_rows: list[dict[str, Any]] = []
    for index, item in enumerate(payload.items):
        item_rows.append(
            await repo.add_meal_item(
                meal_id=meal_row["id"],
                position=index,
                display_name=item.display_name,
                quantity_text=item.quantity_text,
                normalized_quantity_value=item.normalized_quantity_value,
                normalized_quantity_unit=item.normalized_quantity_unit,
                usda_fdc_id=item.usda_fdc_id,
                usda_description=item.usda_description,
                custom_food_id=item.custom_food_id,
                calories=item.calories,
                protein_g=item.protein_g,
                carbs_g=item.carbs_g,
                fat_g=item.fat_g,
                now=now,
            )
        )
    return meal_row, item_rows


async def log_meal(
    session: AsyncSession,
    user_key: str,
    meal_id: UUID,
    now: DateTimeValue,
    consumed_at: DateTimeValue | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Expand a stored meal into food entries sharing one ``entry_group_id``.

    Opens a transaction, loads the meal and its items, then delegates to
    :func:`create_entries_with_side_effects` with server-controlled
    ``meal_id`` / ``meal_name`` set on every inserted row.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session.
    - user_key (str): Owning user's scoping key.
    - meal_id (UUID): Target meal id.
    - now (DateTimeValue): Default ``consumed_at`` when not specified.
    - consumed_at (DateTimeValue | None): Explicit consumption time; defaults
      to ``now``.

    **Outputs:**
    - tuple[list[dict[str, Any]], list[dict[str, Any]]]: Created entry rows
      and the full daily-log rows used for totals (mirrors
      :func:`create_entries_with_side_effects`).

    **Exceptions:**
    - fastapi.HTTPException: Raised with 404 when the meal does not exist
      for this user, or with 400 when the meal has no items.
    """
    async with transaction(session):
        repo = MealsRepository(session)
        meal = await repo.get_meal(meal_id, user_key)
        if meal is None:
            raise HTTPException(status_code=404, detail="Meal not found")

        items = await repo.list_items(meal_id)
        if not items:
            raise HTTPException(status_code=400, detail="Meal has no items to log")

        effective_consumed_at = consumed_at or now
        meal_name = meal["name"]
        entry_items = [
            FoodEntryCreate(
                display_name=item["display_name"],
                quantity_text=item["quantity_text"],
                normalized_quantity_value=optional_float(item["normalized_quantity_value"]),
                normalized_quantity_unit=item["normalized_quantity_unit"],
                usda_fdc_id=item["usda_fdc_id"],
                usda_description=item["usda_description"],
                custom_food_id=item["custom_food_id"],
                calories=int(item["calories"]),
                protein_g=float(item["protein_g"]),
                carbs_g=float(item["carbs_g"]),
                fat_g=float(item["fat_g"]),
                consumed_at=effective_consumed_at,
            )
            for item in items
        ]
        return await create_entries_with_side_effects(
            session=session,
            user_key=user_key,
            items=entry_items,
            now=now,
            manage_transaction=False,
            meal_id=meal_id,
            meal_name=meal_name,
        )


async def assert_meal_alias_available(
    session: AsyncSession,
    user_key: str,
    alias: str,
    exclude_meal_id: UUID | None,
) -> None:
    """Verify an alias is not already used as a meal name or alias on another meal.

    Thin wrapper over :func:`assert_alias_available` bound to the ``meals`` table.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session.
    - user_key (str): Owning user's scoping key.
    - alias (str): Normalized alias to check.
    - exclude_meal_id (UUID | None): Meal id to exclude from the check (the
      meal being edited).

    **Outputs:**
    - None: Returns nothing when no collision is found.

    **Raises:**
    - ValueError: Raised when ``alias`` collides with another meal.
    - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    """
    await assert_alias_available(
        session,
        table=meals_table,
        name_column=meals_table.c.normalized_name,
        aliases_column=meals_table.c.aliases,
        user_key=user_key,
        alias=alias,
        exclude_value=exclude_meal_id,
        exclude_column=meals_table.c.id,
        entity_label="meal",
    )
