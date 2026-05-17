"""DTOs for the /measures/photos endpoints."""

from __future__ import annotations

from datetime import date as DateValue, datetime as DateTimeValue
from typing import Literal

from pydantic import BaseModel

ProgressPhotoSlot = Literal["front", "left", "right", "back"]
ALLOWED_SLOTS: tuple[ProgressPhotoSlot, ...] = ("front", "left", "right", "back")


class ProgressPhotoMetadata(BaseModel):
    date: DateValue
    slot: ProgressPhotoSlot
    mime: str
    bytes: int
    sha256: str
    updated_at: DateTimeValue
