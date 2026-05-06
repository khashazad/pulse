from __future__ import annotations

import uuid
from datetime import datetime as DateTimeValue
from typing import Any, Sequence

from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.db import transaction
from nutrition_server.models import FoodEntryCreate
from nutrition_server.repositories.entries import EntriesRepository
from nutrition_server.services.log_ids import daily_log_id


# Summary: Creates food entries atomically for a user request.
# Parameters:
# - session (AsyncSession): Active SQLAlchemy session used for the transaction.
# - user_key (str): User identifier owning created rows.
# - items (Sequence[FoodEntryCreate]): Requested food entries to persist.
# - now (DateTimeValue): Request-scoped timestamp used for default date/time fields.
# Returns:
# - tuple[list[dict[str, Any]], list[dict[str, Any]]]: Newly created rows and rows used for `daily_totals`
#   (full daily log when the batch targets exactly one calendar date; otherwise the created rows only).
# Raises/Throws:
# - sqlalchemy.exc.SQLAlchemyError: Raised when any SQL operation fails; transaction is rolled back.
async def create_entries_with_side_effects(
    session: AsyncSession,
    user_key: str,
    items: Sequence[FoodEntryCreate],
    now: DateTimeValue,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    entries_repo = EntriesRepository(session)
    created_rows: list[dict[str, Any]] = []

    async with transaction(session):
        batch_entry_group_id = uuid.uuid4()
        for item in items:
            log_date = item.date or now.date()
            consumed_at = item.consumed_at or now
            current_daily_log_id = daily_log_id(user_key, log_date)

            await entries_repo.ensure_daily_log(current_daily_log_id, user_key, log_date)
            created_rows.append(
                await entries_repo.create_food_entry(
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
                )
            )

        unique_log_dates = {item.date or now.date() for item in items}
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
