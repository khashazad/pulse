"""DTOs for the /containers endpoints.

Defines the request/response shapes used to create, update, list, and
inspect "containers" — user-saved tare-weight presets (bowls, jars,
tupperware) referenced when weighing food. Consumed by the containers
router and service layer.
"""

from __future__ import annotations

from datetime import datetime as DateTimeValue
from uuid import UUID

from pydantic import BaseModel, Field


class ContainerCreate(BaseModel):
    """Request body for ``POST /containers`` — register a new tare-weight preset."""

    name: str = Field(min_length=1, max_length=200)
    tare_weight_g: float = Field(gt=0)


class ContainerUpdate(BaseModel):
    """Request body for ``PATCH /containers/{id}`` — partial update of a container."""

    name: str | None = Field(default=None, min_length=1, max_length=200)
    tare_weight_g: float | None = Field(default=None, gt=0)


class ContainerResponse(BaseModel):
    """Response body representing one container row, including photo-presence flag."""

    id: UUID
    user_key: str
    name: str
    normalized_name: str
    tare_weight_g: float
    has_photo: bool
    created_at: DateTimeValue
    updated_at: DateTimeValue


class ContainersListResponse(BaseModel):
    """Response body for ``GET /containers`` — wraps the container list."""

    containers: list[ContainerResponse]


class ContainerPhotoStatus(BaseModel):
    """Response body for ``HEAD``/status checks on a container's reference photo."""

    has_photo: bool
