"""HTTP endpoints for saved meals and the meal-log shortcut.

Exposes the ``/meals`` router covering meal CRUD, per-item CRUD nested under
``/meals/{id}/items``, and ``POST /meals/{id}/log`` which expands a meal's
items into individual food entries that share an ``entry_group_id``. Heavy
work — creating meals with their items, logging meals atomically — lives in
:mod:`services.meals_service`.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.auth import require_session
from pulse_server.config import get_settings
from pulse_server.db import get_session_dependency, transaction
from pulse_server.macro_aggregates import sum_food_entry_macros
from pulse_server.models import (
    FoodEntryResponse,
    MacroTotals,
    MealCreate,
    MealItemCreate,
    MealItemResponse,
    MealResponse,
    MealUpdate,
    MealsListResponse,
    meal_item_response,
    meal_response,
    meal_summary,
)
from pulse_server.repositories.meals import MealsRepository
from pulse_server.services.custom_foods_service import (
    CrossTenantReferenceError,
    assert_custom_foods_owned,
)
from pulse_server.services.meals_service import create_meal_with_items, log_meal
from pulse_server.services.normalize import normalize_name
from pydantic import BaseModel

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_session)])
TZ = ZoneInfo(settings.timezone)


class LogMealRequest(BaseModel):
    """Request body for ``POST /meals/{id}/log``.

    A naive ``consumed_at`` is treated as wall-clock time in the configured
    timezone (``TZ``); ``None`` defers to the server's current time.
    """

    consumed_at: DateTimeValue | None = None


class LogMealResponse(BaseModel):
    """Response body for ``POST /meals/{id}/log``: created entries plus updated daily totals."""

    entries: list[FoodEntryResponse]
    daily_totals: MacroTotals


@router.get("/meals", response_model=MealsListResponse)
async def list_meals(
    request: Request,
    session: AsyncSession = Depends(get_session_dependency),
) -> MealsListResponse:
    """List meals owned by the authenticated user with item counts and aggregate macros.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - MealsListResponse: Per-meal summaries (no item bodies).
    """
    user_key = request.state.user_key
    repo = MealsRepository(session)
    rows = await repo.list_meals(user_key)
    return MealsListResponse(meals=[meal_summary(row) for row in rows])


@router.post("/meals", status_code=201, response_model=MealResponse)
async def create_meal(
    request: Request,
    body: MealCreate,
    session: AsyncSession = Depends(get_session_dependency),
) -> MealResponse:
    """Create a meal together with its pre-scaled items in one transaction.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - body (MealCreate): Meal metadata and items.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - MealResponse: The newly persisted meal with its items.

    **Exceptions:**
    - HTTPException(409): Raised when the user already owns a meal with that name.
    """
    user_key = request.state.user_key
    now = DateTimeValue.now(tz=TZ)
    try:
        async with transaction(session):
            meal_row, item_rows = await create_meal_with_items(
                session=session, user_key=user_key, payload=body, now=now
            )
    except IntegrityError as exc:
        raise HTTPException(status_code=409, detail="Meal name already exists") from exc
    return meal_response(meal_row, item_rows)


@router.get("/meals/{meal_id}", response_model=MealResponse)
async def get_meal(
    request: Request,
    meal_id: UUID,
    session: AsyncSession = Depends(get_session_dependency),
) -> MealResponse:
    """Fetch a meal by id with all its items.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - meal_id (UUID): Meal primary key.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - MealResponse: The meal and its items.

    **Exceptions:**
    - HTTPException(404): Raised when no meal with that id is owned by the user.
    """
    user_key = request.state.user_key
    repo = MealsRepository(session)
    meal_row = await repo.get_meal(meal_id, user_key)
    if meal_row is None:
        raise HTTPException(status_code=404, detail="Meal not found")
    item_rows = await repo.list_items(meal_id)
    return meal_response(meal_row, item_rows)


@router.patch("/meals/{meal_id}", response_model=MealResponse)
async def update_meal(
    request: Request,
    meal_id: UUID,
    body: MealUpdate,
    session: AsyncSession = Depends(get_session_dependency),
) -> MealResponse:
    """Update a meal's name or notes; recomputes ``normalized_name`` when ``name`` changes.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - meal_id (UUID): Meal primary key.
    - body (MealUpdate): Subset of fields to overwrite.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - MealResponse: The updated meal with its items.

    **Exceptions:**
    - HTTPException(409): Raised when renaming would collide with another meal's name.
    - HTTPException(404): Raised when no meal with that id is owned by the user.
    """
    user_key = request.state.user_key
    fields = body.model_dump(exclude_unset=True)
    if "name" in fields and fields["name"] is not None:
        fields["normalized_name"] = normalize_name(fields["name"])
    now = DateTimeValue.now(tz=TZ)
    repo = MealsRepository(session)
    try:
        async with transaction(session):
            meal_row = await repo.update_meal(meal_id, user_key, fields, now)
    except IntegrityError as exc:
        raise HTTPException(status_code=409, detail="Meal name already exists") from exc
    if meal_row is None:
        raise HTTPException(status_code=404, detail="Meal not found")
    item_rows = await repo.list_items(meal_id)
    return meal_response(meal_row, item_rows)


@router.delete("/meals/{meal_id}", status_code=204)
async def delete_meal(
    request: Request,
    meal_id: UUID,
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    """Delete a meal and cascade-delete its items.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - meal_id (UUID): Meal primary key.
    - session (AsyncSession): DB session dependency.

    **Exceptions:**
    - HTTPException(404): Raised when no meal with that id is owned by the user.
    """
    user_key = request.state.user_key
    repo = MealsRepository(session)
    async with transaction(session):
        deleted = await repo.delete_meal(meal_id, user_key)
    if not deleted:
        raise HTTPException(status_code=404, detail="Meal not found")


@router.post("/meals/{meal_id}/items", status_code=201, response_model=MealItemResponse)
async def add_meal_item(
    request: Request,
    meal_id: UUID,
    body: MealItemCreate,
    session: AsyncSession = Depends(get_session_dependency),
) -> MealItemResponse:
    """Append a new item to a meal. The item must reference exactly one food source.

    Position is assigned server-side via ``next_position``. The item must
    specify exactly one of ``usda_fdc_id`` or ``custom_food_id``; if USDA is
    used, ``usda_description`` is required.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - meal_id (UUID): Owning meal's primary key.
    - body (MealItemCreate): Item payload (display name, quantity, food pointer, macros).
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - MealItemResponse: The newly created item.

    **Exceptions:**
    - HTTPException(422): Raised when food-pointer cardinality is wrong, USDA description is missing, or custom_food_id is not owned by the user.
    - HTTPException(404): Raised when the meal does not exist for this user.
    """
    user_key = request.state.user_key
    has_usda = body.usda_fdc_id is not None
    has_custom = body.custom_food_id is not None
    if has_usda == has_custom:
        raise HTTPException(
            status_code=422,
            detail="Item must specify exactly one of usda_fdc_id or custom_food_id",
        )
    if has_usda and not body.usda_description:
        raise HTTPException(
            status_code=422,
            detail="usda_description is required when usda_fdc_id is set",
        )
    now = DateTimeValue.now(tz=TZ)
    repo = MealsRepository(session)
    async with transaction(session):
        meal_row = await repo.get_meal(meal_id, user_key)
        if meal_row is None:
            raise HTTPException(status_code=404, detail="Meal not found")
        if has_custom:
            try:
                await assert_custom_foods_owned(session, user_key, [body.custom_food_id])
            except CrossTenantReferenceError as exc:
                raise HTTPException(status_code=422, detail=str(exc)) from exc
        position = await repo.next_position(meal_id)
        row = await repo.add_meal_item(
            meal_id=meal_id,
            position=position,
            display_name=body.display_name,
            quantity_text=body.quantity_text,
            normalized_quantity_value=body.normalized_quantity_value,
            normalized_quantity_unit=body.normalized_quantity_unit,
            usda_fdc_id=body.usda_fdc_id,
            usda_description=body.usda_description,
            custom_food_id=body.custom_food_id,
            calories=body.calories,
            protein_g=body.protein_g,
            carbs_g=body.carbs_g,
            fat_g=body.fat_g,
            now=now,
        )
    return meal_item_response(row)


@router.delete("/meals/{meal_id}/items/{item_id}", status_code=204)
async def delete_meal_item(
    request: Request,
    meal_id: UUID,
    item_id: UUID,
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    """Delete a single item from a meal.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - meal_id (UUID): Owning meal's primary key.
    - item_id (UUID): Meal-item primary key.
    - session (AsyncSession): DB session dependency.

    **Exceptions:**
    - HTTPException(404): Raised when the meal or the item does not exist for this user.
    """
    user_key = request.state.user_key
    repo = MealsRepository(session)
    async with transaction(session):
        meal_row = await repo.get_meal(meal_id, user_key)
        if meal_row is None:
            raise HTTPException(status_code=404, detail="Meal not found")
        deleted = await repo.delete_meal_item(item_id, meal_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="Meal item not found")


@router.post("/meals/{meal_id}/log", response_model=LogMealResponse)
async def log_meal_endpoint(
    request: Request,
    meal_id: UUID,
    body: LogMealRequest | None = None,
    session: AsyncSession = Depends(get_session_dependency),
) -> LogMealResponse:
    """Expand every meal item into a food entry sharing one ``entry_group_id``.

    A naive ``consumed_at`` is interpreted in the configured timezone; ``None``
    defers to the server's current wall-clock time.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - meal_id (UUID): Meal to log.
    - body (LogMealRequest | None): Optional payload carrying ``consumed_at``.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - LogMealResponse: The created entries plus updated daily macro totals.
    """
    user_key = request.state.user_key
    now = DateTimeValue.now(tz=TZ)
    consumed_at = body.consumed_at if body else None
    if consumed_at is not None and consumed_at.tzinfo is None:
        consumed_at = consumed_at.replace(tzinfo=TZ)
    created_rows, day_rows = await log_meal(
        session=session,
        user_key=user_key,
        meal_id=meal_id,
        now=now,
        consumed_at=consumed_at,
    )
    entries = [FoodEntryResponse(**row) for row in created_rows]
    day_entries = [FoodEntryResponse(**row) for row in day_rows]
    return LogMealResponse(entries=entries, daily_totals=sum_food_entry_macros(day_entries))
