from __future__ import annotations

import io

import pytest
from PIL import Image

from diet_tracker_server.services.container_photos import (
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


def test_rejects_oversized_dimensions(monkeypatch: pytest.MonkeyPatch) -> None:
    """Decompression-bomb guard: image whose decoded pixel count exceeds
    MAX_PIXELS must be rejected before any pixel allocation."""
    from diet_tracker_server.services import container_photos as svc

    monkeypatch.setattr(svc, "MAX_PIXELS", 100)
    src = _png_bytes(20, 20)  # 400 pixels > 100
    with pytest.raises(UnsupportedImageError) as excinfo:
        svc.process_container_photo(src, max_bytes=10 * 1024 * 1024)
    assert "exceed" in str(excinfo.value).lower()


def test_exif_orientation_is_baked_into_pixels() -> None:
    """A landscape JPEG with orientation=6 (rotate 90° CW) should come back
    as a portrait image after re-encoding (EXIF is dropped, so the orientation
    has to be applied to the pixels first)."""
    img = Image.new("RGB", (200, 100), color=(50, 100, 150))
    exif = img.getexif()
    exif[0x0112] = 6  # Orientation tag: rotate 90° CW
    buf = io.BytesIO()
    img.save(buf, format="JPEG", exif=exif.tobytes())
    src = buf.getvalue()

    full, _thumb, _mime = process_container_photo(src, max_bytes=10 * 1024 * 1024)
    full_img = Image.open(io.BytesIO(full))
    # Was 200x100 landscape; after EXIF transpose becomes 100x200 portrait.
    assert full_img.size[0] < full_img.size[1], (
        f"expected portrait (h>w) after EXIF transpose, got {full_img.size}"
    )
