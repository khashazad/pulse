"""Shared image processing pipeline: resize + thumbnail + EXIF normalize."""

from __future__ import annotations

import io
from typing import Final

from PIL import Image, ImageOps, UnidentifiedImageError

MAX_FULL_PX: Final[int] = 1600
MAX_THUMB_PX: Final[int] = 256
JPEG_QUALITY: Final[int] = 82
MAX_PIXELS: Final[int] = 25_000_000  # decompression-bomb guard


class ImageProcessingError(ValueError):
    """Base class for image-processing failures."""


class PhotoTooLargeError(ImageProcessingError):
    """Raw payload exceeds the byte cap."""


class UnsupportedImageError(ImageProcessingError):
    """Bytes can't be decoded, or dimensions exceed the pixel cap."""


def _resize(img: Image.Image, max_edge: int) -> Image.Image:
    w, h = img.size
    longest = max(w, h)
    if longest <= max_edge:
        return img.copy()
    scale = max_edge / longest
    return img.resize((round(w * scale), round(h * scale)), Image.LANCZOS)


def _encode_jpeg(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.convert("RGB").save(buf, format="JPEG", quality=JPEG_QUALITY, optimize=True)
    return buf.getvalue()


def process_photo(
    raw: bytes | bytearray | memoryview, *, max_bytes: int
) -> tuple[bytes, bytes, str]:
    """Return ``(full_jpeg, thumb_jpeg, mime)`` after resize + EXIF normalization.

    - Caps long edge of full to 1600 px; thumb to 256 px.
    - Rejects images whose decoded dimensions exceed MAX_PIXELS
      (decompression-bomb guard, checked before any pixel allocation).
    - Applies EXIF orientation to the pixels, then re-encodes to JPEG (strips EXIF).
    - Raises ImageProcessingError when raw exceeds max_bytes.
    - Raises ImageProcessingError for undecodable input or images that
      trigger Pillow's decompression-bomb protection.
    """
    if len(raw) > max_bytes:
        raise PhotoTooLargeError(
            f"photo exceeds {max_bytes} bytes (got {len(raw)})"
        )
    data = bytes(raw)
    try:
        with Image.open(io.BytesIO(data)) as im:
            if im.width * im.height > MAX_PIXELS:
                raise UnsupportedImageError("photo exceeds pixel budget")
            im = ImageOps.exif_transpose(im) or im
            im.load()
            full = _resize(im, MAX_FULL_PX)
            thumb = _resize(full, MAX_THUMB_PX)
            return _encode_jpeg(full), _encode_jpeg(thumb), "image/jpeg"
    except ImageProcessingError:
        raise
    except Image.DecompressionBombError as exc:
        raise UnsupportedImageError(f"Decompression bomb: {exc}") from exc
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        raise UnsupportedImageError(str(exc)) from exc
