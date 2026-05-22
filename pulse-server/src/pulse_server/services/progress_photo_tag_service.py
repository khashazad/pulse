"""Business logic for progress-photo tags.

Wraps :class:`ProgressPhotoTagRepository` with name normalization, default
tag seeding (front/left/right/back) on a user's first read, and
HTTP-error mapping for duplicate-name conflicts and rename validation.
Tag deletion is intentionally not implemented in this release.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from datetime import timezone as TimezoneValue
from typing import Any
from uuid import UUID

from fastapi import HTTPException, status
from sqlalchemy.exc import IntegrityError

from pulse_server.repositories.progress_photo_tag import ProgressPhotoTagRepository
from pulse_server.services.normalize import normalize_name

DEFAULT_TAGS: tuple[tuple[str, int], ...] = (
    ("front", 0),
    ("left", 1),
    ("right", 2),
    ("back", 3),
)


async def list_tags(
    *, repo: ProgressPhotoTagRepository, user_key: str
) -> list[dict[str, Any]]:
    """List a user's tags, seeding the catalog on first call.

    When the user has no tag rows yet, inserts the canonical defaults
    (``front``, ``left``, ``right``, ``back``) so the UI always has at
    least these four to pick from without an extra round trip.

    **Inputs:**
    - repo (ProgressPhotoTagRepository): Repository bound to the active session.
    - user_key (str): Owning user's scoping key.

    **Outputs:**
    - list[dict[str, Any]]: Tag rows in catalog order.
    """
    rows = await repo.list_for_user(user_key)
    if rows:
        return rows
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    defaults = [(name, name, order) for name, order in DEFAULT_TAGS]
    await repo.bulk_seed_if_empty(user_key=user_key, defaults=defaults, now=now)
    return await repo.list_for_user(user_key)


async def create_tag(
    *,
    repo: ProgressPhotoTagRepository,
    user_key: str,
    name: str,
) -> dict[str, Any]:
    """Create a new tag for a user, validating uniqueness by normalized name.

    **Inputs:**
    - repo (ProgressPhotoTagRepository): Repository bound to the active session.
    - user_key (str): Owning user's scoping key.
    - name (str): Display name as supplied by the user; must be non-empty
      after trimming.

    **Outputs:**
    - dict[str, Any]: The newly inserted tag row.

    **Exceptions:**
    - fastapi.HTTPException: 400 when ``name`` is blank after normalization;
      409 when a tag with the same normalized name already exists.
    """
    normalized = normalize_name(name)
    if not normalized:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="tag name must not be blank",
        )
    existing = await repo.list_for_user(user_key)
    next_order = max((row["sort_order"] for row in existing), default=-1) + 1
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    try:
        return await repo.create(
            user_key=user_key,
            name=name.strip(),
            normalized_name=normalized,
            sort_order=next_order,
            now=now,
        )
    except IntegrityError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="a tag with that name already exists",
        ) from exc


async def update_tag(
    *,
    repo: ProgressPhotoTagRepository,
    user_key: str,
    tag_id: UUID,
    name: str | None,
    sort_order: int | None,
) -> dict[str, Any]:
    """Rename or reorder an existing tag.

    **Inputs:**
    - repo (ProgressPhotoTagRepository): Repository bound to the active session.
    - user_key (str): Owning user's scoping key.
    - tag_id (UUID): Tag primary key.
    - name (str | None): New display name, or ``None`` to leave unchanged.
    - sort_order (int | None): New sort position, or ``None`` to leave unchanged.

    **Outputs:**
    - dict[str, Any]: Updated tag row.

    **Exceptions:**
    - fastapi.HTTPException: 404 when no tag matches; 400 when the new
      ``name`` is blank; 409 when the new ``normalized_name`` collides with
      another tag.
    """
    fields: dict[str, Any] = {}
    if name is not None:
        normalized = normalize_name(name)
        if not normalized:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="tag name must not be blank",
            )
        fields["name"] = name.strip()
        fields["normalized_name"] = normalized
    if sort_order is not None:
        fields["sort_order"] = sort_order
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    try:
        row = await repo.update_fields(
            tag_id=tag_id, user_key=user_key, fields=fields, now=now
        )
    except IntegrityError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="a tag with that name already exists",
        ) from exc
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="tag not found"
        )
    return row
