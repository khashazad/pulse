"""Container-photo facade. Delegates to the shared image pipeline."""

from __future__ import annotations

from diet_tracker_server.services.image_processing import (
    ImageProcessingError,
    process_photo,
)

# Backwards compatibility: the router and tests reference PhotoTooLargeError
# and UnsupportedImageError. Map them to the unified ImageProcessingError.
PhotoTooLargeError = ImageProcessingError
UnsupportedImageError = ImageProcessingError


def process_container_photo(
    raw: bytes | bytearray | memoryview, *, max_bytes: int
) -> tuple[bytes, bytes, str]:
    return process_photo(raw, max_bytes=max_bytes)


__all__ = ["PhotoTooLargeError", "UnsupportedImageError", "process_container_photo"]
