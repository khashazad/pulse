from __future__ import annotations

import io

import pytest
from PIL import Image

from nutrition_server.services.container_photos import (
    PhotoTooLargeError,
    UnsupportedImageError,
    process_container_photo,
)


def _png_bytes(width: int, height: int) -> bytes:
    img = Image.new("RGB", (width, height), color=(200, 100, 50))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def test_returns_full_and_thumb_jpeg() -> None:
    src = _png_bytes(800, 600)
    full, thumb, mime = process_container_photo(src, max_bytes=10 * 1024 * 1024)
    assert mime == "image/jpeg"
    full_img = Image.open(io.BytesIO(full))
    thumb_img = Image.open(io.BytesIO(thumb))
    assert full_img.format == "JPEG"
    assert thumb_img.format == "JPEG"
    assert max(thumb_img.size) == 256
    assert max(full_img.size) <= 1600


def test_caps_full_size_to_1600() -> None:
    src = _png_bytes(3000, 1500)
    full, _thumb, _mime = process_container_photo(src, max_bytes=10 * 1024 * 1024)
    full_img = Image.open(io.BytesIO(full))
    assert max(full_img.size) == 1600


def test_does_not_upscale_smaller_images() -> None:
    src = _png_bytes(400, 300)
    full, _thumb, _mime = process_container_photo(src, max_bytes=10 * 1024 * 1024)
    full_img = Image.open(io.BytesIO(full))
    assert full_img.size == (400, 300)


def test_too_large_input_raises() -> None:
    with pytest.raises(PhotoTooLargeError):
        process_container_photo(b"\x00" * (1024 + 1), max_bytes=1024)


def test_non_image_input_raises() -> None:
    with pytest.raises(UnsupportedImageError):
        process_container_photo(b"this is not an image", max_bytes=10 * 1024 * 1024)
