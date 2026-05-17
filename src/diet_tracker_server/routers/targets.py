"""HTTP endpoints for reading and writing the user's macro target profile.

Exposes ``GET /targets`` (current profile) and ``PUT /targets`` (upsert).
Backed by :class:`TargetsRepository`; one row per user_key keyed by
calories/protein/carbs/fat plus an optional ``target_weight_lb``.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.auth import require_session
from diet_tracker_server.config import get_settings
from diet_tracker_server.db import get_session_dependency, transaction
from diet_tracker_server.models import MacroTargets
from diet_tracker_server.repositories.targets import TargetsRepository

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_session)])
TZ = ZoneInfo(settings.timezone)


@router.get("/targets", response_model=MacroTargets)
async def get_targets(
    request: Request,
    session: AsyncSession = Depends(get_session_dependency),
) -> MacroTargets:
    """Fetch the user's currently configured macro targets.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - MacroTargets: Active calorie/protein/carbs/fat targets plus optional target weight.

    **Exceptions:**
    - HTTPException(404): Raised when no target profile exists for the user.
    - RuntimeError: Raised when the database pool is not initialized.
    - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    """
    user_key = request.state.user_key
    repository = TargetsRepository(session)
    row = await repository.get_target_profile(user_key)

    if row is None:
        raise HTTPException(status_code=404, detail=f"No target profile for user {user_key}")

    return MacroTargets(
        calories=int(row["calories_target"]),
        protein_g=float(row["protein_g_target"]),
        carbs_g=float(row["carbs_g_target"]),
        fat_g=float(row["fat_g_target"]),
        target_weight_lb=float(row["target_weight_lb"]) if row.get("target_weight_lb") is not None else None,
    )


@router.put("/targets", response_model=MacroTargets)
async def update_targets(
    request: Request,
    body: MacroTargets,
    session: AsyncSession = Depends(get_session_dependency),
) -> MacroTargets:
    """Create or update the user's macro target profile (idempotent upsert).

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - body (MacroTargets): Desired macro target values.
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - MacroTargets: The persisted target values (echo of ``body``).

    **Exceptions:**
    - RuntimeError: Raised when the database pool is not initialized.
    - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    """
    user_key = request.state.user_key
    now = DateTimeValue.now(tz=TZ)
    repository = TargetsRepository(session)
    async with transaction(session):
        await repository.upsert_targets(
            user_key=user_key,
            calories=body.calories,
            protein_g=body.protein_g,
            carbs_g=body.carbs_g,
            fat_g=body.fat_g,
            target_weight_lb=body.target_weight_lb,
            updated_at=now,
        )

    return body
