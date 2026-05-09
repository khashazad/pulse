from __future__ import annotations

import io

from PIL import Image, UnidentifiedImageError

FULL_LONG_EDGE = 1600
THUMB_LONG_EDGE = 256
JPEG_QUALITY = 82


class PhotoTooLargeError(ValueError):
    pass


class UnsupportedImageError(ValueError):
    pass


def _resize_long_edge(img: Image.Image, long_edge: int) -> Image.Image:
    w, h = img.size
    if max(w, h) <= long_edge:
        return img
    scale = long_edge / max(w, h)
    new_size = (int(round(w * scale)), int(round(h * scale)))
    return img.resize(new_size, Image.LANCZOS)


def _to_jpeg_bytes(img: Image.Image) -> bytes:
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=JPEG_QUALITY, optimize=True)
    return buf.getvalue()


def process_container_photo(
    raw: bytes,
    *,
    max_bytes: int,
) -> tuple[bytes, bytes, str]:
    """Validate and re-encode an uploaded image into (full_jpeg, thumb_jpeg, mime).

    - Caps long edge of full to 1600 px; thumb to 256 px.
    - Always re-encodes to JPEG (strips EXIF).
    - Raises PhotoTooLargeError when raw exceeds max_bytes.
    - Raises UnsupportedImageError when bytes do not decode as an image.
    """
    if len(raw) > max_bytes:
        raise PhotoTooLargeError(
            f"Image is {len(raw)} bytes; max allowed is {max_bytes}"
        )
    try:
        with Image.open(io.BytesIO(raw)) as img:
            img.load()
            full = _to_jpeg_bytes(_resize_long_edge(img, FULL_LONG_EDGE))
            thumb = _to_jpeg_bytes(_resize_long_edge(img, THUMB_LONG_EDGE))
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        raise UnsupportedImageError(str(exc)) from exc
    return full, thumb, "image/jpeg"
