"""Shared multipart-upload helpers for photo-bearing routers.

Single home for the capped streaming read used by both the container-photo
and progress-photo upload endpoints, so the two routers cannot drift on chunk
size, cap semantics, or error type (previously each kept its own copy with a
different return type and a different overflow exception).
"""

from __future__ import annotations

from fastapi import UploadFile

from pulse_server.services.image_processing import PhotoTooLargeError

_UPLOAD_CHUNK_BYTES = 64 * 1024


async def read_capped(file: UploadFile, max_bytes: int) -> bytearray:
    """Read an UploadFile in 64 KiB chunks, aborting once cumulative bytes exceed ``max_bytes``.

    Returns a ``bytearray`` (not ``bytes``) so the payload is held in a single
    contiguous buffer — no second copy at the join step. Downstream (Pillow via
    ``BytesIO``, repo ``BYTEA`` insert, object-store put) accepts bytes-like
    values. Raises the domain error rather than ``HTTPException`` so each
    caller chooses its own HTTP mapping.

    **Inputs:**
    - file (UploadFile): Streaming multipart file handle.
    - max_bytes (int): Inclusive cap on total payload size in bytes.

    **Outputs:**
    - bytearray: The fully buffered payload, length ≤ ``max_bytes``.

    **Raises:**
    - PhotoTooLargeError: Raised once the running total would exceed ``max_bytes``.
    """
    buffer = bytearray()
    while True:
        chunk = await file.read(_UPLOAD_CHUNK_BYTES)
        if not chunk:
            break
        if len(buffer) + len(chunk) > max_bytes:
            raise PhotoTooLargeError(
                f"Upload exceeds {max_bytes}-byte cap (read at least {len(buffer) + len(chunk)})"
            )
        buffer.extend(chunk)
    return buffer
