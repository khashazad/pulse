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

    if (
        payload.default_portion_id is not None
        and payload.default_portion_id not in payload.portion_ids
    ):
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
    updated = await foods_repo.update_fields(
        food_id, user_key, {"default_portion_id": default_portion_id}, now
    )
    if updated is not None:
        food_row = updated

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
                aliases=list((mem.get("aliases") if mem else None) or []) or None,
            )
    return True


async def _portions_and_aliases(
    session: AsyncSession,
    user_key: str,
    food_id: UUID,
) -> tuple[list[dict[str, Any]], list[str]]:
    """Fetch a Food's portion rows and its memory aliases.

    **Inputs:**
    - session (AsyncSession): Active session.
    - user_key (str): Owning user.
    - food_id (UUID): Food id.

    **Outputs:**
    - tuple[list[dict[str, Any]], list[str]]: The Food's portion rows and the
      aliases from its ``food_memory`` row (empty when it has none).
    """
    cf_repo = CustomFoodsRepository(session)
    mem_repo = FoodMemoryRepository(session)
    portions = await cf_repo.list_by_food(food_id)
    mem = await mem_repo.get_by_food_id(user_key, food_id)
    aliases = list((mem.get("aliases") if mem else None) or [])
    return portions, aliases


async def fetch_food_with_portions(
    session: AsyncSession,
    user_key: str,
    food_id: UUID,
) -> tuple[dict[str, Any], list[dict[str, Any]], list[str]] | None:
    """Fetch one Food with its portions + aliases, or ``None`` when not owned.

    **Inputs:**
    - session (AsyncSession): Active session.
    - user_key (str): Owning user.
    - food_id (UUID): Food id.

    **Outputs:**
    - tuple[dict, list[dict], list[str]] | None: ``(food_row, portion_rows,
      aliases)``, or ``None`` when the Food is not owned by the user.
    """
    foods_repo = FoodsRepository(session)
    food = await foods_repo.get_by_id(food_id, user_key)
    if food is None:
        return None
    portions, aliases = await _portions_and_aliases(session, user_key, food_id)
    return food, portions, aliases


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
    food_rows = await foods_repo.list_for_user(user_key)
    out: list[tuple[dict[str, Any], list[dict[str, Any]], list[str]]] = []
    for food in food_rows:
        portions, aliases = await _portions_and_aliases(session, user_key, food["id"])
        out.append((food, portions, aliases))
    standalones = await cf_repo.list_standalone(user_key)
    return out, standalones


async def attach_portion(
    session: AsyncSession,
    user_key: str,
    food_id: UUID,
    custom_food_id: UUID,
    label: str | None,
    now: DateTimeValue,
) -> None:
    """Attach an existing custom food to a Food as a portion.

    Derives the portion label when not given, links the custom food, harvests
    the portion's standalone name and any aliases it already had, and folds
    them into the Food's alias list (mirroring the roll-up done by
    ``group_foods``). The standalone memory row is deleted before the Food
    memory row is updated so the alias-uniqueness constraint does not reject
    a name that is both a live row and an alias on another row.

    **Inputs:**
    - session (AsyncSession): Active session; caller owns the transaction.
    - user_key (str): Owning user.
    - food_id (UUID): Parent Food id.
    - custom_food_id (UUID): Custom food to attach.
    - label (str | None): Explicit portion label; derived when ``None``.
    - now (DateTimeValue): Timestamp.

    **Outputs:**
    - None.

    **Raises:**
    - HTTPException(404): The Food or the custom food is not owned by the user.
    """
    foods_repo = FoodsRepository(session)
    cf_repo = CustomFoodsRepository(session)
    mem_repo = FoodMemoryRepository(session)
    food = await foods_repo.get_by_id(food_id, user_key)
    if food is None:
        raise HTTPException(status_code=404, detail="Food not found")
    cf = await cf_repo.get_by_id(custom_food_id, user_key)
    if cf is None:
        raise HTTPException(status_code=404, detail="Custom food not found")
    # Harvest the portion's own name + its standalone aliases to fold into the Food.
    harvested = {cf["normalized_name"]}
    mem = await mem_repo.get_by_name(user_key, cf["normalized_name"])
    if mem is not None:
        harvested.update(mem.get("aliases") or [])
    portion_label = label or derive_portion_label(food["name"], cf["name"])
    await cf_repo.set_food_link(custom_food_id, user_key, food_id, portion_label, now)
    # Remove the standalone memory row BEFORE folding its names into the Food's
    # aliases (alias-uniqueness trigger rejects a name that is also a live row).
    await mem_repo.delete_by_name(user_key, cf["normalized_name"])
    food_mem = await mem_repo.get_by_food_id(user_key, food_id)
    existing = set(food_mem.get("aliases") or []) if food_mem else set()
    new_aliases = (existing | harvested) - {food["normalized_name"]}
    # Use add_alias (plain UPDATE) for each new alias rather than upsert_food
    # (which attempts an INSERT first, causing the alias-uniqueness trigger to
    # compare the new aliases against the pre-existing Apple row using a
    # different id, yielding a false collision on already-held aliases).
    for alias in sorted(new_aliases - existing):
        await mem_repo.add_alias(user_key, food["normalized_name"], alias, now)


async def detach_portion(
    session: AsyncSession,
    user_key: str,
    food_id: UUID,
    custom_food_id: UUID,
    now: DateTimeValue,
) -> None:
    """Detach a portion from a Food, restoring it as a standalone custom food.

    Strips the portion's name from the Food's aliases (the alias-uniqueness
    trigger rejects a standalone row whose name is still an alias elsewhere),
    then recreates the portion's own memory row so it resolves again.

    **Inputs:**
    - session (AsyncSession): Active session; caller owns the transaction.
    - user_key (str): Owning user.
    - food_id (UUID): Parent Food id.
    - custom_food_id (UUID): Portion to detach.
    - now (DateTimeValue): Timestamp.

    **Outputs:**
    - None.

    **Raises:**
    - HTTPException(404): The Food is not owned by the user, or the custom
      food is not found among this Food's portions.
    """
    foods_repo = FoodsRepository(session)
    cf_repo = CustomFoodsRepository(session)
    mem_repo = FoodMemoryRepository(session)
    food = await foods_repo.get_by_id(food_id, user_key)
    if food is None:
        raise HTTPException(status_code=404, detail="Food not found")
    cf = await cf_repo.get_by_id(custom_food_id, user_key)
    if cf is None or cf.get("food_id") != food_id:
        raise HTTPException(status_code=404, detail="Portion not found in this food")
    await cf_repo.set_food_link(custom_food_id, user_key, None, None, now)
    # If the detached portion was the Food's default, repoint to a remaining one.
    if food.get("default_portion_id") == custom_food_id:
        remaining = await cf_repo.list_by_food(food_id)
        new_default = remaining[0]["id"] if remaining else None
        await foods_repo.update_fields(food_id, user_key, {"default_portion_id": new_default}, now)
    # Strip the portion's name from the Food's aliases (the alias-uniqueness
    # trigger rejects a standalone row whose name is still an alias), then
    # restore the portion's own memory row so it resolves again.
    await mem_repo.remove_alias(user_key, food["normalized_name"], cf["normalized_name"], now)
    await mem_repo.upsert_custom(
        user_key=user_key,
        name=cf["name"],
        normalized_name=cf["normalized_name"],
        custom_food_id=custom_food_id,
        now=now,
    )


async def update_food(
    session: AsyncSession,
    user_key: str,
    food_id: UUID,
    fields: dict[str, Any],
    aliases: list[str] | None,
    now: DateTimeValue,
) -> None:
    """Update a Food's fields and reconcile its memory row.

    Computes ``normalized_name`` when the name changes, moves the memory row off
    the old name (deleting it) and onto the new name preserving aliases, and
    strips the new normalized name from its own alias list.

    **Inputs:**
    - session (AsyncSession): Active session; caller owns the transaction.
    - user_key (str): Owning user.
    - food_id (UUID): Food id.
    - fields (dict[str, Any]): Column→value updates (e.g. ``name``,
      ``default_portion_id``); ``aliases`` is passed separately.
    - aliases (list[str] | None): New alias list, or ``None`` to leave aliases
      unchanged (preserved across a rename).
    - now (DateTimeValue): Timestamp.

    **Outputs:**
    - None.

    **Raises:**
    - HTTPException(404): The Food is not owned by the user.
    """
    foods_repo = FoodsRepository(session)
    mem_repo = FoodMemoryRepository(session)
    food = await foods_repo.get_by_id(food_id, user_key)
    if food is None:
        raise HTTPException(status_code=404, detail="Food not found")
    if "name" in fields and fields["name"] is not None:
        fields = {**fields, "normalized_name": normalize_name(fields["name"])}
    old_norm = food["normalized_name"]
    existing_mem = await mem_repo.get_by_food_id(user_key, food_id)
    existing_aliases = list((existing_mem.get("aliases") if existing_mem else None) or [])
    if fields:
        await foods_repo.update_fields(food_id, user_key, fields, now)
    new_name = fields.get("name", food["name"])
    new_norm = fields.get("normalized_name", old_norm)
    renaming = new_norm != old_norm
    if renaming:
        await mem_repo.delete_by_name(user_key, old_norm)
    if aliases is not None:
        new_aliases: list[str] | None = [normalize_name(a) for a in aliases]
    elif renaming:
        new_aliases = existing_aliases
    else:
        new_aliases = None
    if new_aliases is not None:
        new_aliases = [a for a in new_aliases if a != new_norm]
    if new_aliases is not None or renaming:
        await mem_repo.upsert_food(
            user_key=user_key,
            name=new_name,
            normalized_name=new_norm,
            food_id=food_id,
            now=now,
            aliases=new_aliases,
        )
