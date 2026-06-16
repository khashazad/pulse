"""Foods (portion-parent) write-path business logic.

Composes :class:`FoodsRepository`, :class:`CustomFoodsRepository`, and
:class:`FoodMemoryRepository` to group existing custom foods under a Food,
ungroup them, and list Foods with their portions. Callers control the
transaction boundary.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.models import FoodCreate
from pulse_server.repositories.custom_foods import CustomFoodsRepository
from pulse_server.repositories.food_memory import FoodMemoryRepository
from pulse_server.repositories.foods import FoodsRepository
from pulse_server.services.custom_foods_service import (
    CrossTenantReferenceError,
    assert_custom_foods_owned,
)
from pulse_server.services.normalize import normalize_name


def derive_portion_label(food_name: str, portion_name: str) -> str:
    """Derive a portion label by stripping the Food's name tokens from the portion name.

    **Inputs:**
    - food_name (str): The parent Food's display name (e.g. ``"Apple"``).
    - portion_name (str): The portion's original custom-food name (e.g.
      ``"medium apple"``).

    **Outputs:**
    - str: The remaining tokens joined (``"medium"``); the original
      ``portion_name`` when stripping leaves nothing (a bare base variant).
    """
    food_tokens = set(normalize_name(food_name).split())
    remaining = [
        token for token in portion_name.split() if normalize_name(token) not in food_tokens
    ]
    label = " ".join(remaining).strip()
    return label or portion_name


async def group_foods(
    session: AsyncSession,
    user_key: str,
    payload: FoodCreate,
    now: DateTimeValue,
) -> tuple[dict[str, Any], list[dict[str, Any]], list[str]]:
    """Create a Food from existing custom foods (portions) in one transaction.

    Links each portion (``food_id`` + derived/explicit label), sets the default
    portion, and rolls the portions' memory aliases up to the Food. Alias-fold
    order matters: portion memory rows are deleted *before* the Food memory row
    is written so the alias-uniqueness trigger does not collide on a portion's
    own normalized name.

    **Inputs:**
    - session (AsyncSession): Active session; caller owns the transaction.
    - user_key (str): Owning user.
    - payload (FoodCreate): Name, portion ids, optional labels/default/aliases.
    - now (DateTimeValue): Timestamp.

    **Outputs:**
    - tuple[dict, list[dict], list[str]]: The Food row, its portion rows, and
      the Food's rolled-up aliases.

    **Raises:**
    - HTTPException(422): A portion id is not owned by the user.
    - HTTPException(400): ``default_portion_id`` is not among the portions.
    - HTTPException(409): A Food with that name already exists.
    """
    foods_repo = FoodsRepository(session)
    cf_repo = CustomFoodsRepository(session)
    mem_repo = FoodMemoryRepository(session)

    try:
        await assert_custom_foods_owned(session, user_key, payload.portion_ids)
    except CrossTenantReferenceError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    if payload.default_portion_id is not None and payload.default_portion_id not in payload.portion_ids:
        raise HTTPException(status_code=400, detail="default_portion_id must be one of portion_ids")

    normalized = normalize_name(payload.name)

    try:
        food_row = await foods_repo.create(
            user_key=user_key, name=payload.name, normalized_name=normalized, notes=None, now=now
        )
    except IntegrityError as exc:
        raise HTTPException(status_code=409, detail="A food with that name already exists") from exc
    food_id = food_row["id"]

    # Harvest portion names + their memory aliases, then link each portion.
    harvested: set[str] = set()
    portion_rows: list[dict[str, Any]] = []
    for cfid in payload.portion_ids:
        cf = await cf_repo.get_by_id(cfid, user_key)
        if cf is None:  # pragma: no cover - guarded by assert_custom_foods_owned
            raise HTTPException(status_code=422, detail=f"custom_food_id {cfid} not found")
        harvested.add(cf["normalized_name"])
        mem = await mem_repo.get_by_name(user_key, cf["normalized_name"])
        if mem is not None:
            harvested.update(mem.get("aliases") or [])
        label = payload.portion_labels.get(cfid) or derive_portion_label(payload.name, cf["name"])
        linked = await cf_repo.set_food_link(cfid, user_key, food_id, label, now)
        portion_rows.append(linked if linked is not None else cf)

    # Default portion: explicit, else the first portion.
    default_portion_id = payload.default_portion_id or payload.portion_ids[0]
    await foods_repo.update_fields(
        food_id, user_key, {"default_portion_id": default_portion_id}, now
    )

    # Delete portion memory rows BEFORE writing the Food memory row.
    for normalized_portion_name in {
        cf["normalized_name"] for cf in portion_rows if cf.get("normalized_name")
    }:
        await mem_repo.delete_by_name(user_key, normalized_portion_name)

    # Roll up aliases onto the Food memory row (deduped, minus the Food's own name).
    rolled = {normalize_name(a) for a in harvested}
    rolled.update(normalize_name(a) for a in payload.aliases)
    rolled.discard(normalized)
    rolled_list = sorted(rolled)
    await mem_repo.upsert_food(
        user_key=user_key,
        name=payload.name,
        normalized_name=normalized,
        food_id=food_id,
        now=now,
        aliases=rolled_list,
    )

    food_row = await foods_repo.get_by_id(food_id, user_key) or food_row
    portion_rows = await cf_repo.list_by_food(food_id)
    return food_row, portion_rows, rolled_list


async def ungroup_food(
    session: AsyncSession,
    user_key: str,
    food_id: UUID,
    now: DateTimeValue,
) -> bool:
    """Ungroup a Food: detach portions, delete the Food, push aliases back down.

    The Food's aliases are recreated as a custom-food memory entry on the former
    default portion so the common lookup keeps resolving after ungroup.

    **Inputs:**
    - session (AsyncSession): Active session; caller owns the transaction.
    - user_key (str): Owning user.
    - food_id (UUID): Food to dissolve.
    - now (DateTimeValue): Timestamp.

    **Outputs:**
    - bool: ``True`` when the Food existed and was ungrouped.
    """
    foods_repo = FoodsRepository(session)
    cf_repo = CustomFoodsRepository(session)
    mem_repo = FoodMemoryRepository(session)

    food = await foods_repo.get_by_id(food_id, user_key)
    if food is None:
        return False

    mem = await mem_repo.get_by_food_id(user_key, food_id)
    target_portion = food.get("default_portion_id")
    portions = await cf_repo.list_by_food(food_id)
    if target_portion is None and portions:
        target_portion = portions[0]["id"]

    # Delete the Food memory row first (frees the normalized name + aliases).
    await mem_repo.delete_by_name(user_key, food["normalized_name"])
    # Detach portions (food_id -> null).
    await cf_repo.clear_food_link_for_food(food_id, user_key, now)
    await foods_repo.delete(food_id, user_key)

    # Push the Food's name + aliases back onto the former default portion.
    if target_portion is not None:
        target = await cf_repo.get_by_id(target_portion, user_key)
        if target is not None:
            await mem_repo.upsert_custom(
                user_key=user_key,
                name=food["name"],
                normalized_name=food["normalized_name"],
                custom_food_id=target_portion,
                now=now,
            )
            for alias in (mem.get("aliases") if mem else None) or []:
                await mem_repo.add_alias(user_key, food["normalized_name"], alias, now)
    return True


async def list_foods_with_portions(
    session: AsyncSession,
    user_key: str,
) -> tuple[list[tuple[dict[str, Any], list[dict[str, Any]], list[str]]], list[dict[str, Any]]]:
    """List every Food with its portions + aliases, plus ungrouped standalones.

    **Inputs:**
    - session (AsyncSession): Active session.
    - user_key (str): Owning user.

    **Outputs:**
    - tuple: ``(foods, standalones)`` where each food entry is
      ``(food_row, portion_rows, aliases)`` and standalones are custom-food rows.
    """
    foods_repo = FoodsRepository(session)
    cf_repo = CustomFoodsRepository(session)
    mem_repo = FoodMemoryRepository(session)

    food_rows = await foods_repo.list_for_user(user_key)
    out: list[tuple[dict[str, Any], list[dict[str, Any]], list[str]]] = []
    for food in food_rows:
        portions = await cf_repo.list_by_food(food["id"])
        mem = await mem_repo.get_by_food_id(user_key, food["id"])
        aliases = list((mem.get("aliases") if mem else None) or [])
        out.append((food, portions, aliases))
    standalones = await cf_repo.list_standalone(user_key)
    return out, standalones
