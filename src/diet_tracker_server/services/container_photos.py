"""Container-photo facade over the shared image-processing pipeline.

Provides :func:`process_container_photo`, a thin wrapper around
:func:`diet_tracker_server.services.image_processing.process_photo` that
exists so container-specific call sites (custom-food container uploads) have
a stable, named entry point. Re-exports the pipeline's error types
(``PhotoTooLargeError``, ``UnsupportedImageError``) so HTTP layers can map
them to 413/415 without importing the lower-level module directly.
"""

from __future__ import annotations

from diet_tracker_server.services.image_processing import (
    PhotoTooLargeError,
    UnsupportedImageError,
    process_photo,
)


def process_container_photo(
    raw: bytes | bytearray | memoryview, *, max_bytes: int
) -> tuple[bytes, bytes, str]:
    """Run the shared image pipeline on a container-photo upload.

    Delegates verbatim to :func:`process_photo`; the wrapper exists purely as
    a stable name for container-specific call sites.

    **Inputs:**
    - raw (bytes | bytearray | memoryview): Raw upload bytes.
    - max_bytes (int): Hard byte cap; payloads larger than this are rejected.

    **Outputs:**
    - tuple[bytes, bytes, str]: ``(full_jpeg, thumb_jpeg, mime)`` — resized
      full-resolution JPEG, thumbnail JPEG, and the MIME type (always
      ``"image/jpeg"``).

    **Exceptions:**
    - PhotoTooLargeError: Raised when ``len(raw) > max_bytes``.
    - UnsupportedImageError: Raised when the payload cannot be decoded or
      exceeds the pixel-count guard.
    """
    return process_photo(raw, max_bytes=max_bytes)


__all__ = ["PhotoTooLargeError", "UnsupportedImageError", "process_container_photo"]
