"""DTOs for the /measures/photos endpoints.

Defines :class:`ProgressPhotoMetadata` (per-slot metadata returned by
the list/get endpoints) and the ``ProgressPhotoSlot`` literal plus its
``ALLOWED_SLOTS`` tuple used to validate inbound slot values. Consumed
by the progress-photo router, service, and repository.
"""

from __future__ import annotations

from datetime import date as DateValue, datetime as DateTimeValue
from typing import Literal

from pydantic import BaseModel

ProgressPhotoSlot = Literal["front", "left", "right", "back"]
ALLOWED_SLOTS: tuple[ProgressPhotoSlot, ...] = ("front", "left", "right", "back")


class ProgressPhotoMetadata(BaseModel):
    """Response fragment describing one stored progress photo's metadata."""

    date: DateValue
    slot: ProgressPhotoSlot
    mime: str
    bytes: int
    sha256: str
    updated_at: DateTimeValue
