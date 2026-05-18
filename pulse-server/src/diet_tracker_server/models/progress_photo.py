"""DTOs for the /measures/photos and /measures/photo-tags endpoints.

Defines :class:`ProgressPhotoMetadata` (per-photo metadata returned by the
list/upload endpoints) and :class:`ProgressPhotoTag` (user-defined tag rows
returned by the tag CRUD endpoints) plus the request bodies for creating
and renaming tags. Consumed by the progress-photo router, service, and
repository.
"""

from __future__ import annotations

from datetime import date as DateValue, datetime as DateTimeValue
from uuid import UUID

from pydantic import BaseModel, Field


class ProgressPhotoTag(BaseModel):
    """A user-defined progress-photo tag."""

    id: UUID
    name: str
    normalized_name: str
    sort_order: int
    created_at: DateTimeValue
    updated_at: DateTimeValue


class ProgressPhotoTagCreate(BaseModel):
    """Body for creating a new progress-photo tag."""

    name: str = Field(min_length=1, max_length=64)


class ProgressPhotoTagUpdate(BaseModel):
    """Body for renaming or reordering a progress-photo tag."""

    name: str | None = Field(default=None, min_length=1, max_length=64)
    sort_order: int | None = None


class ProgressPhotoMetadata(BaseModel):
    """Response fragment describing one stored progress photo's metadata."""

    id: UUID
    date: DateValue
    tag_id: UUID
    mime: str
    bytes: int
    sha256: str
    updated_at: DateTimeValue
