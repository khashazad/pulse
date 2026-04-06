from __future__ import annotations

from datetime import datetime as DateTimeValue
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.auth import require_api_key
from nutrition_server.config import get_settings
from nutrition_server.db import get_session_dependency, transaction
from nutrition_server.models import MacroTargets
from nutrition_server.repositories.targets import TargetsRepository

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_api_key)])
TZ = ZoneInfo(settings.timezone)


# Summary: Fetches the user's currently configured macro targets.
# Parameters:
# - user_key (str | None): Optional user identifier override.
# Returns:
# - MacroTargets: Active calorie/protein/carbs/fat targets for the user.
# Raises/Throws:
# - fastapi.HTTPException: Raised with 404 when no target profile exists for the user.
# - RuntimeError: Raised when the database pool is not initialized.
# - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
@router.get("/targets", response_model=MacroTargets)
async def get_targets(
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> MacroTargets:
    effective_user_key = user_key or settings.default_user_key
    repository = TargetsRepository(session)
    row = await repository.get_target_profile(effective_user_key)

    if row is None:
        raise HTTPException(status_code=404, detail=f"No target profile for user {effective_user_key}")

    return MacroTargets(
        calories=int(row["calories_target"]),
        protein_g=float(row["protein_g_target"]),
        carbs_g=float(row["carbs_g_target"]),
        fat_g=float(row["fat_g_target"]),
    )


# Summary: Creates or updates the user's macro target profile.
# Parameters:
# - body (MacroTargets): Requested macro target values.
# - user_key (str | None): Optional user identifier override.
# Returns:
# - MacroTargets: Persisted macro target values.
# Raises/Throws:
# - RuntimeError: Raised when the database pool is not initialized.
# - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
@router.put("/targets", response_model=MacroTargets)
async def update_targets(
    body: MacroTargets,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> MacroTargets:
    effective_user_key = user_key or settings.default_user_key
    now = DateTimeValue.now(tz=TZ)
    repository = TargetsRepository(session)
    async with transaction(session):
        await repository.upsert_targets(
            user_key=effective_user_key,
            calories=body.calories,
            protein_g=body.protein_g,
            carbs_g=body.carbs_g,
            fat_g=body.fat_g,
            updated_at=now,
        )

    return body
