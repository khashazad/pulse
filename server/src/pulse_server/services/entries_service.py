"""Food-entry creation orchestration.

Provides :func:`create_entries_with_side_effects`, the single write-path for
adding food entries: ensures the owning ``daily_log`` row exists for each
unique date in the batch, inserts each :class:`FoodEntryCreate`, stamps a
shared ``entry_group_id`` for the batch, and returns both the freshly
created rows and the daily-totals row set used by callers to recompute
day-level macros. Optionally accepts a server-controlled ``meal_id`` /
``meal_name`` pair used by ``log_meal`` to mark entries as belonging to a
saved meal. Composes :class:`EntriesRepository` and :func:`daily_log_id`.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.db import transaction
from pulse_server.log_ids import daily_log_id
from pulse_server.models import FoodEntryCreate
from pulse_server.repositories.entries import EntriesRepository, FoodEntryPayload
from pulse_server.services.custom_foods_service import assert_custom_foods_owned


async def create_entries_with_side_effects(
    session: AsyncSession,
    user_key: str,
    items: Sequence[FoodEntryCreate],
    now: DateTimeValue,
    manage_transaction: bool = True,
    meal_id: UUID | None = None,
    meal_name: str | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Create food entries atomically for a user request.

    Ensures a ``daily_log`` row exists for every unique date in the batch,
    assigns a single shared ``entry_group_id``, and returns both the
    inserted rows and the daily-totals row set used to recompute day macros
    (the full daily log when the batch targets exactly one date, otherwise
    just the created rows).

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session used for the
      transaction.
    - user_key (str): User identifier owning the created rows.
    - items (Sequence[FoodEntryCreate]): Requested food entries to persist.
    - now (DateTimeValue): Request-scoped timestamp used for default date and
      ``consumed_at`` fields when items omit them.
    - manage_transaction (bool): When ``True`` (default), opens a new
      transaction on the session. Pass ``False`` when the caller already
      holds an active transaction on this session.
    - meal_id (UUID | None): Server-controlled meal id stamped on every row
      in the batch. Only set by ``log_meal``; public callers leave this
      ``None``.
    - meal_name (str | None): Server-controlled meal-name snapshot stamped
      on every row in the batch. Mirrors ``meal_id``'s contract.

    **Outputs:**
    - tuple[list[dict[str, Any]], list[dict[str, Any]]]: Newly created rows
      and rows used for ``daily_totals`` (full daily log when the batch
      targets exactly one calendar date; otherwise the created rows only).

    **Exceptions:**
    - sqlalchemy.exc.SQLAlchemyError: Raised when any SQL operation fails;
      the transaction is rolled back when this function manages it.
    """
    if manage_transaction:
        async with transaction(session):
            return await _create_entries(session, user_key, items, now, meal_id, meal_name)
    return await _create_entries(session, user_key, items, now, meal_id, meal_name)


async def _create_entries(
    session: AsyncSession,
    user_key: str,
    items: Sequence[FoodEntryCreate],
    now: DateTimeValue,
    meal_id: UUID | None,
    meal_name: str | None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Internal worker that performs the actual inserts inside a transaction.

    Assumes the caller (``create_entries_with_side_effects``) has already
    opened or skipped a transaction as appropriate.

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session.
    - user_key (str): Owning user's scoping key.
    - items (Sequence[FoodEntryCreate]): Entries to insert.
    - now (DateTimeValue): Default date/time when items omit them.
    - meal_id (UUID | None): Optional meal id stamped on every inserted row.
    - meal_name (str | None): Optional meal-name snapshot stamped on every
      inserted row.

    **Outputs:**
    - tuple[list[dict[str, Any]], list[dict[str, Any]]]: ``(created_rows,
      totals_rows)`` — see :func:`create_entries_with_side_effects`.

    **Exceptions:**
    - sqlalchemy.exc.SQLAlchemyError: Raised on any SQL failure.
    """
    # Reject references to custom foods the user doesn't own before any insert.
    # The food_entries FK only proves the UUID exists, not that it belongs to
    # this user (see CrossTenantReferenceError).
    await assert_custom_foods_owned(session, user_key, (item.custom_food_id for item in items))

    entries_repo = EntriesRepository(session)
    created_rows: list[dict[str, Any]] = []
    batch_entry_group_id = uuid.uuid4()
    for item in items:
        log_date = _effective_log_date(item.consumed_at, now)
        consumed_at = item.consumed_at or now
        current_daily_log_id = daily_log_id(user_key, log_date)

        await entries_repo.ensure_daily_log(current_daily_log_id, user_key, log_date)
        created_rows.append(
            await entries_repo.create_food_entry(
                FoodEntryPayload(
                    entry_id=uuid.uuid4(),
                    daily_log_id=current_daily_log_id,
                    user_key=user_key,
                    entry_group_id=batch_entry_group_id,
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
                    consumed_at=consumed_at,
                    meal_id=meal_id,
                    meal_name=meal_name,
                )
            )
        )

    unique_log_dates = {_effective_log_date(item.consumed_at, now) for item in items}
    if not items:
        totals_log_id = daily_log_id(user_key, now.date())
        all_rows = await entries_repo.list_entries_by_daily_log_id(totals_log_id)
    elif len(unique_log_dates) == 1:
        totals_date = next(iter(unique_log_dates))
        totals_log_id = daily_log_id(user_key, totals_date)
        all_rows = await entries_repo.list_entries_by_daily_log_id(totals_log_id)
    else:
        all_rows = list(created_rows)

    return created_rows, all_rows


def _effective_log_date(
    item_consumed_at: DateTimeValue | None,
    now: DateTimeValue,
) -> DateValue:
    """Resolve the daily-log calendar date for an entry from its consumption time.

    Projects ``item_consumed_at`` into ``now``'s timezone so the entry rolls up
    into the correct calendar day; falls back to ``now.date()`` when no
    consumption timestamp is supplied.

    **Inputs:**
    - item_consumed_at (datetime | None): Explicit consumption timestamp.
    - now (datetime): Request-scoped tz-aware reference timestamp.

    **Outputs:**
    - date: The resolved daily-log calendar date.
    """
    if item_consumed_at is None:
        return now.date()
    if now.tzinfo is not None and item_consumed_at.tzinfo is not None:
        return item_consumed_at.astimezone(now.tzinfo).date()
    return item_consumed_at.date()
