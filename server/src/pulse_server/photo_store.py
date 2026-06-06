"""Photo object-store factory and process-wide provider.

Builds the S3-compatible store (Cloudflare R2 in production) used for
progress-photo bytes, falling back to a local filesystem store in
local-style environments so dev needs zero setup. Mirrors
:mod:`pulse_server.usda_provider`: the lifespan publishes the store here and
routers resolve it via :func:`get_photo_store`.
"""

from __future__ import annotations

from pathlib import Path

from obstore.store import LocalStore, MemoryStore, S3Store

from pulse_server.config import Settings

# Every backend obstore exposes shares the same method surface; this alias is
# what services/routers type against so tests can inject a MemoryStore.
PhotoStore = S3Store | LocalStore | MemoryStore

_store: PhotoStore | None = None


def build_photo_store(settings: Settings) -> PhotoStore:
    """Construct the photo store appropriate for the current configuration.

    **Inputs:**
    - settings (Settings): Application settings; ``s3_configured`` selects the
      S3 backend, otherwise ``photo_store_dir`` selects a filesystem store.

    **Outputs:**
    - PhotoStore: An ``S3Store`` (region ``auto``, R2-compatible) when S3 is
      configured, else a ``LocalStore`` rooted at ``photo_store_dir`` (created
      if missing).
    """
    if settings.s3_configured:
        return S3Store(
            settings.s3_bucket,
            endpoint=settings.s3_endpoint,
            access_key_id=settings.s3_access_key_id,
            secret_access_key=settings.s3_secret_access_key,
            region="auto",
        )
    root = Path(settings.photo_store_dir)
    root.mkdir(parents=True, exist_ok=True)
    return LocalStore(root)


def set_photo_store(store: PhotoStore | None) -> None:
    """Publish (or clear) the process-wide photo store.

    Called by the app lifespan to publish the store at startup and clear it at
    shutdown.

    **Inputs:**
    - store (PhotoStore | None): Store instance to publish; ``None`` clears it.

    **Outputs:**
    - None: Mutates module state and returns nothing.
    """
    global _store
    _store = store


def get_photo_store() -> PhotoStore:
    """Return the published photo store; FastAPI dependency for routers.

    **Outputs:**
    - PhotoStore: The store published by the lifespan (or a test fixture).

    **Raises:**
    - RuntimeError: Raised when called before the lifespan published a store.
    """
    if _store is None:
        raise RuntimeError("photo store is not initialized")
    return _store
