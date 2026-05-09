from __future__ import annotations

import io

from PIL import Image, ImageOps, UnidentifiedImageError

FULL_LONG_EDGE = 1600
THUMB_LONG_EDGE = 256
JPEG_QUALITY = 82
# Decompression-bomb guard: reject images whose decoded pixel count exceeds
# this value. 25 MP comfortably covers modern phone cameras (e.g. iPhone 48 MP
# stays under after typical re-encode), and stays well under PIL's default
# MAX_IMAGE_PIXELS (~89 MP) so we fail fast with a clear message.
MAX_PIXELS = 25_000_000


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
    raw: bytes | bytearray | memoryview,
    *,
    max_bytes: int,
) -> tuple[bytes, bytes, str]:
    """Validate and re-encode an uploaded image into (full_jpeg, thumb_jpeg, mime).

    - Caps long edge of full to 1600 px; thumb to 256 px.
    - Rejects images whose decoded dimensions exceed MAX_PIXELS
      (decompression-bomb guard, checked before any pixel allocation).
    - Applies EXIF orientation to the pixels, then re-encodes to JPEG (strips EXIF).
    - Raises PhotoTooLargeError when raw exceeds max_bytes.
    - Raises UnsupportedImageError for undecodable input or images that
      trigger Pillow's decompression-bomb protection.
    """
    if len(raw) > max_bytes:
        raise PhotoTooLargeError(
            f"Image is {len(raw)} bytes; max allowed is {max_bytes}"
        )
    try:
        with Image.open(io.BytesIO(raw)) as img:
            w, h = img.size
            if w * h > MAX_PIXELS:
                raise UnsupportedImageError(
                    f"Image dimensions {w}x{h} exceed {MAX_PIXELS}-pixel cap"
                )
            # Bake EXIF orientation into pixels, then drop EXIF on re-encode.
            oriented = ImageOps.exif_transpose(img) or img
            oriented.load()
            full_src = _resize_long_edge(oriented, FULL_LONG_EDGE)
            full = _to_jpeg_bytes(full_src)
            # Build the thumbnail from the already-downscaled `full_src` so we
            # avoid a second LANCZOS pass on the full-size pixels.
            thumb = _to_jpeg_bytes(_resize_long_edge(full_src, THUMB_LONG_EDGE))
    except UnsupportedImageError:
        raise
    except Image.DecompressionBombError as exc:
        raise UnsupportedImageError(f"Decompression bomb: {exc}") from exc
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        raise UnsupportedImageError(str(exc)) from exc
    return full, thumb, "image/jpeg"
