"""One-off migration: copy progress-photo bytea blobs into the object store.

Usage:
    DATABASE_URL=... S3_ENDPOINT=... S3_BUCKET=... \
    S3_ACCESS_KEY_ID=... S3_SECRET_ACCESS_KEY=... \
    uv run python scripts/migrate_photos_to_object_store.py [--dry-run]

For every ``progress_photos`` row without a ``storage_key_prefix``: upload the
1600px ``photo`` blob as both ``display.jpg`` and ``archive.jpg`` (the best
surviving version — originals were discarded at upload time pre-cutover),
upload ``photo_thumb`` as ``thumb.jpg``, verify the display object's sha256
against the row by reading it back, then stamp the prefix and null the bytea
columns. Idempotent: re-running skips rows that already carry a prefix.

After a successful run, reclaim the table's disk pages with
``vacuum full progress_photos`` (brief table lock).

Delete this script (and its test) once the cleanup phase of the cutover plan
drops the bytea columns.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import sys
from typing import Any

from sqlalchemy import func, select, update

from pulse_server.config import get_settings
from pulse_server.db import close_pool, get_session, init_pool, transaction
from pulse_server.photo_store import PhotoStore, build_photo_store, get_photo_object
from pulse_server.repositories.tables import progress_photos


async def copy_row_objects(store: PhotoStore, row: dict[str, Any]) -> str:
    """Upload one row's blobs as display/archive/thumb objects.

    The stored 1600px ``photo`` blob doubles as the archival copy because the
    pre-cutover pipeline discarded everything above 1600px.

    **Inputs:**
    - store (PhotoStore): Destination object store.
    - row (dict[str, Any]): Mapping with ``id``, ``user_key``, ``photo``,
      ``photo_thumb``.

    **Outputs:**
    - str: The ``storage_key_prefix`` the objects were written under.
    """
    prefix = f"progress/{row['user_key']}/{row['id']}"
    full = bytes(row["photo"])
    await store.put_async(f"{prefix}/display.jpg", full)
    await store.put_async(f"{prefix}/archive.jpg", full)
    await store.put_async(f"{prefix}/thumb.jpg", bytes(row["photo_thumb"]))
    return prefix


async def main() -> int:
    """Migrate every un-migrated row with per-row read-back verification.

    **Outputs:**
    - int: Process exit code; 0 when every row migrated and verified, 1 when
      a verification failed or rows remain without a prefix.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="count and list the rows that would migrate, write nothing",
    )
    args = parser.parse_args()

    settings = get_settings()
    store = build_photo_store(settings)
    await init_pool(settings.database_url)
    try:
        async with get_session() as session:
            ids = (
                (
                    await session.execute(
                        select(progress_photos.c.id)
                        .where(progress_photos.c.storage_key_prefix.is_(None))
                        .order_by(progress_photos.c.created_at)
                    )
                )
                .scalars()
                .all()
            )
        print(f"{len(ids)} rows to migrate")
        if args.dry_run:
            for photo_id in ids:
                print(f"would migrate {photo_id}")
            return 0

        for i, photo_id in enumerate(ids, start=1):
            # One transaction wraps the row read AND the update: a bare SELECT
            # autobegins a transaction on the session, so a later standalone
            # `transaction(session)` would raise "A transaction is already
            # begun on this Session".
            async with get_session() as session, transaction(session):
                row = (
                    (
                        await session.execute(
                            select(
                                progress_photos.c.id,
                                progress_photos.c.user_key,
                                progress_photos.c.photo,
                                progress_photos.c.photo_thumb,
                                progress_photos.c.sha256,
                            ).where(progress_photos.c.id == photo_id)
                        )
                    )
                    .mappings()
                    .one()
                )
                prefix = await copy_row_objects(store, dict(row))
                # Read-back check before nulling anything: the display object
                # must hash to the row's stored sha256. Returning here commits
                # a read-only transaction, which is harmless.
                echoed = await get_photo_object(store, f"{prefix}/display.jpg")
                if echoed is None or hashlib.sha256(bytes(echoed)).hexdigest() != row["sha256"]:
                    print(f"VERIFY FAILED for {photo_id}; aborting before nulling blobs")
                    return 1
                await session.execute(
                    update(progress_photos)
                    .where(progress_photos.c.id == photo_id)
                    .values(storage_key_prefix=prefix, photo=None, photo_thumb=None)
                )
            print(f"[{i}/{len(ids)}] migrated {photo_id}")

        async with get_session() as session:
            remaining = (
                await session.execute(
                    select(func.count())
                    .select_from(progress_photos)
                    .where(progress_photos.c.storage_key_prefix.is_(None))
                )
            ).scalar_one()
        print(f"done; rows still without prefix: {remaining}")
        return 0 if remaining == 0 else 1
    finally:
        await close_pool()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
