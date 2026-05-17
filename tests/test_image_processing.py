from __future__ import annotations

import io

import pytest
from PIL import Image

from diet_tracker_server.services.image_processing import (
    ImageProcessingError,
    MAX_FULL_PX,
    MAX_THUMB_PX,
    process_photo,
)


def _png_bytes(w: int, h: int) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (w, h), (123, 200, 64)).save(buf, format="PNG")
    return buf.getvalue()


def test_process_photo_returns_full_and_thumb_jpegs() -> None:
    src = _png_bytes(2000, 1000)
    full, thumb, mime = process_photo(src, max_bytes=10_000_000)
    assert mime == "image/jpeg"
    full_img = Image.open(io.BytesIO(full))
    thumb_img = Image.open(io.BytesIO(thumb))
    assert max(full_img.size) <= MAX_FULL_PX
    assert max(thumb_img.size) <= MAX_THUMB_PX
    assert full_img.format == "JPEG"
    assert thumb_img.format == "JPEG"


def test_process_photo_rejects_oversize_payload() -> None:
    src = _png_bytes(100, 100)
    with pytest.raises(ImageProcessingError):
        process_photo(src, max_bytes=10)
