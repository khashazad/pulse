"""Regenerate progress_photos thumbnails using current MAX_THUMB_PX.

Usage:
    uv run python scripts/regenerate_progress_thumbs.py [--dry-run] [--user-key khash]

When MAX_THUMB_PX is bumped, existing rows keep their old (smaller) thumb
bytes and render fuzzy in the iOS grid. This script reads each row's
stored full image, re-runs the thumbnail step, and writes the new bytes
back. Idempotent: re-running re-encodes from the same stored full image.
"""

from __future__ import annotations

import argparse
import asyncio
import io
from datetime import UTC
from datetime import datetime as DateTimeValue
from typing import Any

from PIL import Image, ImageOps
from sqlalchemy import select, update

from pulse_server.config import get_settings
from pulse_server.db import close_pool, get_session, init_pool, transaction
from pulse_server.repositories.tables import progress_photos
from pulse_server.services.image_processing import MAX_THUMB_PX, _encode_jpeg, _resize


def _rethumb(full: bytes) -> bytes:
    """Re-encode the thumbnail variant from a stored full-resolution JPEG.

    **Inputs:**
    - full (bytes): Stored ``progress_photos.photo`` blob.

    **Outputs:**
    - bytes: JPEG-encoded thumbnail capped at ``MAX_THUMB_PX``.
    """
    with Image.open(io.BytesIO(full)) as im:
        im = ImageOps.exif_transpose(im) or im
        im.load()
        thumb = _resize(im, MAX_THUMB_PX)
        return _encode_jpeg(thumb)


async def _run(*, user_key: str | None, dry_run: bool) -> None:
    """Iterate every progress_photos row and rewrite its photo_thumb column.

    **Inputs:**
    - user_key (str | None): When set, restrict to one user; otherwise process all.
    - dry_run (bool): When True, report what would be done and skip writes.
    """
    settings = get_settings()
    await init_pool(settings.database_url)

    try:
        async with get_session() as session, transaction(session):
            stmt = select(
                progress_photos.c.id,
                progress_photos.c.user_key,
                progress_photos.c.photo,
            )
            if user_key:
                stmt = stmt.where(progress_photos.c.user_key == user_key)
            stmt = stmt.order_by(progress_photos.c.created_at)
            result = await session.execute(stmt)
            rows: list[dict[str, Any]] = [dict(r) for r in result.mappings().all()]

            print(f"processing {len(rows)} rows (target MAX_THUMB_PX={MAX_THUMB_PX})")
            if dry_run:
                for r in rows[:5]:
                    print(f"  {r['id']} user={r['user_key']} full_bytes={len(r['photo'])}")
                if len(rows) > 5:
                    print(f"  ... +{len(rows) - 5} more")
                return

            now = DateTimeValue.now(tz=UTC)
            written = 0
            for row in rows:
                full = bytes(row["photo"])
                new_thumb = _rethumb(full)
                await session.execute(
                    update(progress_photos)
                    .where(progress_photos.c.id == row["id"])
                    .values(photo_thumb=new_thumb, updated_at=now)
                )
                written += 1
            print(f"rewrote {written} thumbnails")
    finally:
        await close_pool()


def main() -> None:
    """Parse CLI arguments and dispatch to the async runner.

    **Outputs:**
    - None: Side-effect only; prints progress to stdout.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user-key", default=None, help="restrict to one user_key")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    asyncio.run(_run(user_key=args.user_key, dry_run=args.dry_run))


if __name__ == "__main__":
    main()
