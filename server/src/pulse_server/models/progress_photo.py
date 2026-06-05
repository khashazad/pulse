"""DTOs for the /measures/photos and /measures/photo-tags endpoints.

Defines :class:`ProgressPhotoMetadata` (per-photo metadata returned by the
list/upload endpoints), :class:`ProgressPhotoTag` (user-defined tag rows) and
:class:`ProgressPhotoTagResponse` (the wire shape returned by the tag CRUD
endpoints) plus the request bodies for creating and renaming tags. Consumed by
the progress-photo router, service, and repository.
"""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from uuid import UUID

from pydantic import BaseModel, Field, field_serializer


def _isoformat_datetime(value: DateTimeValue) -> str:
    """Serialize a datetime exactly as the legacy dict projectors did.

    FastAPI's default model serializer renders a UTC datetime with a ``Z``
    suffix, whereas the prior plain-dict responses flowed through
    ``jsonable_encoder`` and emitted ``datetime.isoformat()`` (``+00:00``).
    Using ``isoformat`` here keeps the wire bytes byte-identical to the legacy
    output.

    **Inputs:**
    - value (datetime): The timezone-aware timestamp to serialize.

    **Outputs:**
    - str: The ISO-8601 string from ``datetime.isoformat()``.
    """
    return value.isoformat()


class ProgressPhotoTag(BaseModel):
    """A user-defined progress-photo tag."""

    id: UUID
    name: str
    normalized_name: str
    sort_order: int
    created_at: DateTimeValue
    updated_at: DateTimeValue


class ProgressPhotoTagResponse(BaseModel):
    """Response body for one progress-photo tag row returned by the tag CRUD endpoints.

    Field names, order, and types mirror the legacy ``_row_to_response`` dict
    projector exactly so the emitted JSON is byte-identical.
    """

    id: UUID
    name: str
    normalized_name: str
    sort_order: int
    created_at: DateTimeValue
    updated_at: DateTimeValue

    @field_serializer("created_at", "updated_at")
    def _serialize_timestamps(self, value: DateTimeValue) -> str:
        """Render timestamps via ``isoformat`` to match the legacy dict output.

        **Inputs:**
        - value (datetime): Timestamp field being serialized.

        **Outputs:**
        - str: The ``isoformat`` string (``+00:00`` offset for UTC).
        """
        return _isoformat_datetime(value)


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

    @field_serializer("updated_at")
    def _serialize_updated_at(self, value: DateTimeValue) -> str:
        """Render ``updated_at`` via ``isoformat`` to match the legacy dict output.

        **Inputs:**
        - value (datetime): The ``updated_at`` timestamp being serialized.

        **Outputs:**
        - str: The ``isoformat`` string (``+00:00`` offset for UTC).
        """
        return _isoformat_datetime(value)
