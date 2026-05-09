from __future__ import annotations

from datetime import datetime as DateTimeValue
from uuid import UUID

from pydantic import BaseModel, Field


class ContainerCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    tare_weight_g: float = Field(gt=0)


class ContainerUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    tare_weight_g: float | None = Field(default=None, gt=0)


class ContainerResponse(BaseModel):
    id: UUID
    user_key: str
    name: str
    normalized_name: str
    tare_weight_g: float
    has_photo: bool
    created_at: DateTimeValue
    updated_at: DateTimeValue


class ContainersListResponse(BaseModel):
    containers: list[ContainerResponse]


class ContainerPhotoStatus(BaseModel):
    has_photo: bool
