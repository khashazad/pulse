"""Shared image-processing pipeline: resize, thumbnail, and EXIF normalization.

Provides :func:`process_photo`, the single entry point used by both
container-photo and progress-photo upload paths, plus the
:class:`ImageProcessingError` hierarchy mapped to 413/415 HTTP responses by
service-layer wrappers. Caps long-edge dimensions to 1600 px for the full
image and 256 px for the thumbnail, applies EXIF orientation to pixels, then
re-encodes to JPEG (stripping EXIF). Guards against decompression-bomb
inputs by checking decoded pixel count before allocation.
"""

from __future__ import annotations

import io
from typing import Final

from PIL import Image, ImageOps, UnidentifiedImageError

MAX_FULL_PX: Final[int] = 1600
MAX_THUMB_PX: Final[int] = 256
JPEG_QUALITY: Final[int] = 82
MAX_PIXELS: Final[int] = 25_000_000  # decompression-bomb guard


class ImageProcessingError(ValueError):
    """Base class for image-processing failures.

    Subclassed by :class:`PhotoTooLargeError` and
    :class:`UnsupportedImageError`; service-layer code catches the specific
    subclasses to map them to distinct HTTP status codes.
    """


class PhotoTooLargeError(ImageProcessingError):
    """Raised when the raw payload exceeds the configured byte cap."""


class UnsupportedImageError(ImageProcessingError):
    """Raised when bytes can't be decoded or dimensions exceed the pixel cap."""


def _resize(img: Image.Image, max_edge: int) -> Image.Image:
    """Return a copy of ``img`` whose longest edge is at most ``max_edge``.

    Returns an unmodified copy when the image already fits.

    **Inputs:**
    - img (Image.Image): Decoded Pillow image.
    - max_edge (int): Maximum allowed length for the longer edge in pixels.

    **Outputs:**
    - Image.Image: A new image; the original is left untouched.
    """
    w, h = img.size
    longest = max(w, h)
    if longest <= max_edge:
        return img.copy()
    scale = max_edge / longest
    return img.resize((round(w * scale), round(h * scale)), Image.LANCZOS)


def _encode_jpeg(img: Image.Image) -> bytes:
    """Encode an image to JPEG bytes at the module's quality setting.

    Converts to RGB before saving (drops alpha) and enables optimized
    encoding.

    **Inputs:**
    - img (Image.Image): Source image.

    **Outputs:**
    - bytes: JPEG-encoded image bytes.
    """
    buf = io.BytesIO()
    img.convert("RGB").save(buf, format="JPEG", quality=JPEG_QUALITY, optimize=True)
    return buf.getvalue()


def process_photo(
    raw: bytes | bytearray | memoryview, *, max_bytes: int
) -> tuple[bytes, bytes, str]:
    """Return ``(full_jpeg, thumb_jpeg, mime)`` after resize and EXIF normalization.

    Caps the long edge of the full image to 1600 px and the thumbnail to
    256 px, rejects images whose decoded dimensions exceed ``MAX_PIXELS``
    (decompression-bomb guard, checked before pixel allocation), applies
    EXIF orientation to the pixels, and re-encodes to JPEG (stripping EXIF).

    **Inputs:**
    - raw (bytes | bytearray | memoryview): Raw upload bytes.
    - max_bytes (int): Hard byte cap; payloads larger than this are rejected.

    **Outputs:**
    - tuple[bytes, bytes, str]: ``(full_jpeg, thumb_jpeg, mime)`` where
      ``mime`` is always ``"image/jpeg"``.

    **Exceptions:**
    - PhotoTooLargeError: Raised when ``len(raw) > max_bytes``.
    - UnsupportedImageError: Raised when the input cannot be decoded, when
      dimensions exceed ``MAX_PIXELS``, or when Pillow's decompression-bomb
      protection trips.
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
