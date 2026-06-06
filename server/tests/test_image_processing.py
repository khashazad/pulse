"""Unit tests for the generic `services.image_processing.process_photo` helper.

Covers the JPEG full + thumb pair output (with the documented max-edge
bounds) and the oversize-payload guard that raises `ImageProcessingError`.
Also covers :func:`process_progress_photo` for the three-variant archival
encoding added for the object-storage migration.
"""

from __future__ import annotations

import io

import pytest
from PIL import Image

from pulse_server.services.image_processing import (
    MAX_FULL_PX,
    MAX_THUMB_PX,
    ImageProcessingError,
    PhotoTooLargeError,
    process_photo,
    process_progress_photo,
)


def _image_bytes(w: int, h: int, fmt: str = "PNG") -> bytes:
    """Render an in-memory image of the given dimensions and format.

    **Inputs:**
    - w (int): Image width in pixels.
    - h (int): Image height in pixels.
    - fmt (str): Pillow format name (``"PNG"`` or ``"JPEG"``).

    **Outputs:**
    - bytes: Encoded image bytes.
    """
    buf = io.BytesIO()
    Image.new("RGB", (w, h), (123, 200, 64)).save(buf, format=fmt)
    return buf.getvalue()


def test_process_photo_returns_full_and_thumb_jpegs() -> None:
    """`process_photo` returns JPEG full + thumb pair within the configured pixel caps."""
    src = _image_bytes(2000, 1000)
    full, thumb, mime = process_photo(src, max_bytes=10_000_000)
    assert mime == "image/jpeg"
    full_img = Image.open(io.BytesIO(full))
    thumb_img = Image.open(io.BytesIO(thumb))
    assert max(full_img.size) <= MAX_FULL_PX
    assert max(thumb_img.size) <= MAX_THUMB_PX
    assert full_img.format == "JPEG"
    assert thumb_img.format == "JPEG"


def test_process_photo_rejects_oversize_payload() -> None:
    """Inputs exceeding ``max_bytes`` raise `ImageProcessingError`."""
    src = _image_bytes(100, 100)
    with pytest.raises(ImageProcessingError):
        process_photo(src, max_bytes=10)


def test_process_progress_photo_produces_three_variants() -> None:
    """A 4000px source yields a 3000px archive, 1600px display, 1024px thumb."""
    raw = _image_bytes(4000, 2000, "JPEG")
    result = process_progress_photo(raw, max_bytes=20 * 1024 * 1024)
    assert result.mime == "image/jpeg"
    with Image.open(io.BytesIO(result.archive)) as im:
        assert max(im.size) == 3000
    with Image.open(io.BytesIO(result.display)) as im:
        assert max(im.size) == 1600
    with Image.open(io.BytesIO(result.thumb)) as im:
        assert max(im.size) == 1024


def test_process_progress_photo_small_source_not_upscaled() -> None:
    """A source below every cap passes through at native size in all variants."""
    raw = _image_bytes(800, 600, "JPEG")
    result = process_progress_photo(raw, max_bytes=20 * 1024 * 1024)
    for payload in (result.archive, result.display, result.thumb):
        with Image.open(io.BytesIO(payload)) as im:
            assert im.size == (800, 600)


def test_process_progress_photo_rejects_oversize_payload() -> None:
    """Payloads above max_bytes raise PhotoTooLargeError before decoding."""
    with pytest.raises(PhotoTooLargeError):
        process_progress_photo(b"x" * 11, max_bytes=10)
