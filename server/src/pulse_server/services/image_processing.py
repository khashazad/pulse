"""Shared image-processing pipeline: resize, thumbnail, and EXIF normalization.

Provides :func:`process_photo` for container-photo uploads and
:func:`process_progress_photo` for progress-photo uploads, plus the
:class:`ImageProcessingError` hierarchy mapped to 413/415 HTTP responses by
service-layer wrappers. Caps long-edge dimensions to 1600 px for the full
image and 1024 px for the thumbnail, applies EXIF orientation to pixels, then
re-encodes to JPEG (stripping EXIF). Guards against decompression-bomb
inputs by checking decoded pixel count before allocation. Progress-photo
uploads additionally produce a 3000 px q90 archival encoding stored in the
object store via :func:`process_progress_photo`.
"""

from __future__ import annotations

import io
from dataclasses import dataclass
from typing import Final

from PIL import Image, ImageOps, UnidentifiedImageError

MAX_FULL_PX: Final[int] = 1600
# Thumbnails are rendered up to full-screen width on iPhone Pro Max (~430pt
# x 3x = 1290px), so we keep them at 1024 long-edge — sharp at every grid
# density the app shows while still encoding small enough to cache cheaply.
MAX_THUMB_PX: Final[int] = 1024
JPEG_QUALITY: Final[int] = 82
MAX_PIXELS: Final[int] = 25_000_000  # decompression-bomb guard

# Archival derivative: the preservation copy stored in the object store.
# 3000px q90 is visually near-indistinguishable from a phone original for
# progress photos at ~1/3 the bytes; originals are not retained (spec decision).
MAX_ARCHIVE_PX: Final[int] = 3000
ARCHIVE_JPEG_QUALITY: Final[int] = 90


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
    return img.resize((round(w * scale), round(h * scale)), Image.Resampling.LANCZOS)


def _encode_jpeg(img: Image.Image, quality: int = JPEG_QUALITY) -> bytes:
    """Encode an image to JPEG bytes at the given quality level.

    Converts to RGB before saving (drops alpha) and enables optimized
    encoding.

    **Inputs:**
    - img (Image.Image): Source image.
    - quality (int): JPEG quality factor (1-95). Defaults to ``JPEG_QUALITY``
      (82), the display/thumb standard. Pass ``ARCHIVE_JPEG_QUALITY`` (90) for
      archival derivatives.

    **Outputs:**
    - bytes: JPEG-encoded image bytes.
    """
    buf = io.BytesIO()
    img.convert("RGB").save(buf, format="JPEG", quality=quality, optimize=True)
    return buf.getvalue()


def _decode_oriented(data: bytes) -> Image.Image:
    """Decode bytes into an orientation-normalized image, enforcing pixel caps.

    **Inputs:**
    - data (bytes): Raw image bytes.

    **Outputs:**
    - Image.Image: Fully-loaded image with EXIF orientation applied.

    **Exceptions:**
    - UnsupportedImageError: Raised when the image cannot be decoded or its
      decoded dimensions exceed ``MAX_PIXELS``.
    """
    try:
        with Image.open(io.BytesIO(data)) as im:
            if im.width * im.height > MAX_PIXELS:
                raise UnsupportedImageError("photo exceeds pixel budget")
            oriented = ImageOps.exif_transpose(im) or im
            oriented.load()
            return oriented
    except ImageProcessingError:
        raise
    except Image.DecompressionBombError as exc:
        raise UnsupportedImageError(f"Decompression bomb: {exc}") from exc
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        raise UnsupportedImageError(str(exc)) from exc


def process_photo(
    raw: bytes | bytearray | memoryview, *, max_bytes: int
) -> tuple[bytes, bytes, str]:
    """Return ``(full_jpeg, thumb_jpeg, mime)`` after resize and EXIF normalization.

    Caps the long edge of the full image to 1600 px and the thumbnail to
    1024 px, rejects images whose decoded dimensions exceed ``MAX_PIXELS``
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
        raise PhotoTooLargeError(f"photo exceeds {max_bytes} bytes (got {len(raw)})")
    oriented = _decode_oriented(bytes(raw))
    full = _resize(oriented, MAX_FULL_PX)
    thumb = _resize(full, MAX_THUMB_PX)
    return _encode_jpeg(full), _encode_jpeg(thumb), "image/jpeg"


@dataclass(frozen=True)
class ProcessedProgressPhoto:
    """Immutable bundle of the three progress-photo encodings.

    Attributes: ``archive`` (3000px q90 preservation copy), ``display``
    (1600px q82, what the app shows), ``thumb`` (1024px q82 grid thumbnail),
    and ``mime`` (always ``"image/jpeg"``).
    """

    archive: bytes
    display: bytes
    thumb: bytes
    mime: str


def process_progress_photo(
    raw: bytes | bytearray | memoryview, *, max_bytes: int
) -> ProcessedProgressPhoto:
    """Produce archive/display/thumb JPEGs for a progress-photo upload.

    Same guards as :func:`process_photo` (byte cap, pixel budget, EXIF
    orientation + strip), plus a 3000px q90 archival encoding that serves as
    the long-term preservation copy in the object store.

    **Inputs:**
    - raw (bytes | bytearray | memoryview): Raw upload bytes.
    - max_bytes (int): Hard byte cap; larger payloads are rejected.

    **Outputs:**
    - ProcessedProgressPhoto: The three encodings plus MIME type.

    **Exceptions:**
    - PhotoTooLargeError: Raised when ``len(raw) > max_bytes``.
    - UnsupportedImageError: Raised when the input cannot be decoded or
      exceeds the pixel budget.
    """
    if len(raw) > max_bytes:
        raise PhotoTooLargeError(f"photo exceeds {max_bytes} bytes (got {len(raw)})")
    oriented = _decode_oriented(bytes(raw))
    archive = _resize(oriented, MAX_ARCHIVE_PX)
    display = _resize(oriented, MAX_FULL_PX)
    thumb = _resize(display, MAX_THUMB_PX)
    return ProcessedProgressPhoto(
        archive=_encode_jpeg(archive, quality=ARCHIVE_JPEG_QUALITY),
        display=_encode_jpeg(display),
        thumb=_encode_jpeg(thumb),
        mime="image/jpeg",
    )
