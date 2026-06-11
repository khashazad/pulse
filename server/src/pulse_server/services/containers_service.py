"""Business logic for container photos.

Owns the processing + persistence step of a container-photo upload so the
router stays a thin HTTP adapter (mirroring how progress photos go through
:mod:`services.progress_photo_service`). Pillow work runs off the event loop
via ``asyncio.to_thread`` — decode/resize/encode of a multi-megabyte image is
CPU-bound and would otherwise stall every concurrent request on the single
uvicorn worker.
"""

from __future__ import annotations

import asyncio
from datetime import datetime as DateTimeValue
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.db import transaction
from pulse_server.repositories.containers import ContainersRepository
from pulse_server.services.image_processing import process_photo


async def store_photo(
    session: AsyncSession,
    *,
    container_id: UUID,
    user_key: str,
    raw: bytes | bytearray,
    max_bytes: int,
    now: DateTimeValue,
) -> bool:
    """Process an uploaded image and persist full + thumb BYTEA for a container.

    **Inputs:**
    - session (AsyncSession): DB session the write runs on.
    - container_id (UUID): Container primary key.
    - user_key (str): Owning user's scoping key.
    - raw (bytes | bytearray): Raw upload bytes (already size-capped by the router).
    - max_bytes (int): Byte cap forwarded to the image pipeline.
    - now (DateTimeValue): Timestamp written as the row's update time.

    **Outputs:**
    - bool: ``True`` when the photo was stored; ``False`` when no container with
      that id belongs to the user.

    **Raises:**
    - PhotoTooLargeError: When the processed payload exceeds ``max_bytes``.
    - UnsupportedImageError: When the payload is not a decodable image.
    - sqlalchemy.exc.SQLAlchemyError: When the DB write fails.
    """
    full, thumb, mime = await asyncio.to_thread(process_photo, raw, max_bytes=max_bytes)
    repo = ContainersRepository(session)
    async with transaction(session):
        return await repo.set_photo(
            container_id=container_id,
            user_key=user_key,
            photo=full,
            photo_thumb=thumb,
            mime=mime,
            now=now,
        )
