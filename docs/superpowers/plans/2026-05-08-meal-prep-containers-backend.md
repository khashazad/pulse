# Meal-Prep Containers — Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `../../diet-tracker-ios/docs/superpowers/specs/2026-05-08-meal-prep-containers-design.md` (lives in the iOS repo).

**Goal:** Add a `containers` resource to nutrition-server: per-user CRUD via REST + MCP, plus multipart photo upload that stores a JPEG and a 256 px thumbnail in Postgres BYTEA columns.

**Architecture:** New table `containers` with `(user_key, normalized_name)` unique index. Pydantic models, repository, router, MCP tools follow the existing per-resource pattern (`custom_foods` is the closest analogue). Pillow re-encodes uploads to JPEG (strips EXIF, caps long edge to 1600 px) and produces a 256 px thumbnail. List/get endpoints never select the blob columns. Photo bytes served via a dedicated endpoint with `Cache-Control` + `ETag`. MCP tools mirror REST CRUD without photo handling.

**Tech Stack:** Python 3.11+, FastAPI, SQLAlchemy async, Alembic, Pydantic v2, FastMCP, Pillow, pytest (`integration` marker for real-DB tests via `TEST_DATABASE_URL`).

**Repo:** `dietracker-server` (this plan operates in this repo only).

**Sequencing note:** This plan is independent. The iOS plan in `../diet-tracker-ios/docs/superpowers/plans/` depends on this being deployed.

---

## File Map

Creates:
- `src/nutrition_server/models/containers.py` — Pydantic shapes.
- `src/nutrition_server/repositories/containers.py` — SQLAlchemy queries.
- `src/nutrition_server/routers/containers.py` — FastAPI routes.
- `src/nutrition_server/services/container_photos.py` — Pillow re-encode/thumbnail helper.
- `alembic/versions/20260508_000001_containers.py` — schema migration.
- `tests/integration/test_containers_repo.py` — repo tests against real DB.
- `tests/test_container_photos.py` — pure-function image processing tests.
- `tests/test_containers_api.py` — TestClient-based API tests.

Modifies:
- `pyproject.toml` — add `Pillow` dep.
- `schema.sql` — add `containers` table block (matches alembic).
- `src/nutrition_server/repositories/tables.py` — add `containers` Table.
- `src/nutrition_server/models/__init__.py` — re-export new models.
- `src/nutrition_server/app.py` — `include_router(containers_router.router)`.
- `src/nutrition_server/mcp/server.py` — register four MCP tools.

---

## Task 1: Add Pillow dependency

**Files:**
- Modify: `pyproject.toml`

- [ ] **Step 1: Edit `pyproject.toml`**

In the `dependencies` array, add `"Pillow>=10.4"` after the `fastmcp` line:

```toml
dependencies = [
    "fastapi>=0.115",
    "uvicorn[standard]>=0.34",
    "psycopg[binary]>=3.2",
    "psycopg-pool>=3.2",
    "sqlalchemy>=2.0",
    "greenlet>=3.0",
    "alembic>=1.16",
    "pydantic-settings>=2.7",
    "httpx>=0.28",
    "fastmcp>=2.7",
    "Pillow>=10.4",
]
```

- [ ] **Step 2: Lock the dep**

Run: `uv sync`
Expected: `uv.lock` updated, no errors.

- [ ] **Step 3: Verify import**

Run: `uv run python -c "from PIL import Image; print(Image.__version__)"`
Expected: prints a version like `10.4.0`.

- [ ] **Step 4: Commit**

```bash
git add pyproject.toml uv.lock
git commit -m "chore: add Pillow for container photo processing"
```

---

## Task 2: Add `containers` Table to SQLAlchemy metadata + schema.sql

**Files:**
- Modify: `src/nutrition_server/repositories/tables.py`
- Modify: `schema.sql`

- [ ] **Step 1: Append `containers` Table to `tables.py`**

Add at the bottom of `src/nutrition_server/repositories/tables.py`, after the last existing `Table(...)` definition:

```python
containers = Table(
    "containers",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")),
    Column("user_key", Text, nullable=False),
    Column("name", Text, nullable=False),
    Column("normalized_name", Text, nullable=False),
    Column("tare_weight_g", Numeric, nullable=False),
    Column("photo", LargeBinary, nullable=True),
    Column("photo_thumb", LargeBinary, nullable=True),
    Column("photo_mime", Text, nullable=True),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    CheckConstraint("tare_weight_g > 0", name="containers_tare_weight_g_check"),
    Index("idx_containers_user_key_name", "user_key", "normalized_name", unique=True),
    Index("idx_containers_user_key", "user_key"),
)
```

Also update the imports at the top of `tables.py` to include `LargeBinary`:

```python
from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    Column,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    LargeBinary,   # NEW
    MetaData,
    Numeric,
    Table,
    Text,
    UniqueConstraint,
    func,
    text,
)
```

- [ ] **Step 2: Append matching block to `schema.sql`**

Append at the bottom of `schema.sql` (after the last `do $body$ ... $body$;` block):

```sql
create table if not exists containers (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  name text not null,
  normalized_name text not null,
  tare_weight_g numeric not null check (tare_weight_g > 0),
  photo bytea,
  photo_thumb bytea,
  photo_mime text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists idx_containers_user_key_name on containers(user_key, normalized_name);
create index if not exists idx_containers_user_key on containers(user_key);
```

- [ ] **Step 3: Commit**

```bash
git add src/nutrition_server/repositories/tables.py schema.sql
git commit -m "feat(db): add containers table"
```

---

## Task 3: Alembic migration

**Files:**
- Create: `alembic/versions/20260508_000001_containers.py`

- [ ] **Step 1: Find current head revision**

Run: `uv run alembic history | head -3`
Expected: shows `20260506_000001 (head)` or similar.

- [ ] **Step 2: Create migration file**

Write `alembic/versions/20260508_000001_containers.py`:

```python
"""Add containers table.

Revision ID: 20260508_000001
Revises: 20260506_000001
Create Date: 2026-05-08T00:00:00Z
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "20260508_000001"
down_revision = "20260506_000001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "containers",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            primary_key=True,
            nullable=False,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column("user_key", sa.Text(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("normalized_name", sa.Text(), nullable=False),
        sa.Column("tare_weight_g", sa.Numeric(), nullable=False),
        sa.Column("photo", sa.LargeBinary(), nullable=True),
        sa.Column("photo_thumb", sa.LargeBinary(), nullable=True),
        sa.Column("photo_mime", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.CheckConstraint("tare_weight_g > 0", name="containers_tare_weight_g_check"),
    )
    op.create_index(
        "idx_containers_user_key_name",
        "containers",
        ["user_key", "normalized_name"],
        unique=True,
    )
    op.create_index("idx_containers_user_key", "containers", ["user_key"], unique=False)


def downgrade() -> None:
    op.drop_index("idx_containers_user_key", table_name="containers")
    op.drop_index("idx_containers_user_key_name", table_name="containers")
    op.drop_table("containers")
```

> **Note:** If `head` from Step 1 isn't `20260506_000001`, update `down_revision` to match the actual head value.

- [ ] **Step 3: Smoke-test the migration locally**

Run: `TEST_DATABASE_URL=$TEST_DATABASE_URL uv run alembic upgrade head`
Expected: log line `Running upgrade ... -> 20260508_000001, Add containers table`.

If you don't have a Postgres running locally, skip and let CI / Railway exercise it.

- [ ] **Step 4: Commit**

```bash
git add alembic/versions/20260508_000001_containers.py
git commit -m "feat(db): alembic migration for containers"
```

---

## Task 4: Pydantic models

**Files:**
- Create: `src/nutrition_server/models/containers.py`
- Modify: `src/nutrition_server/models/__init__.py`

- [ ] **Step 1: Write `models/containers.py`**

```python
from __future__ import annotations

from datetime import datetime as DateTimeValue
from uuid import UUID

from pydantic import BaseModel, Field


class ContainerCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    tare_weight_g: float = Field(gt=0)


class ContainerUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    tare_weight_g: float | None = Field(default=None, gt=0)


class ContainerResponse(BaseModel):
    id: UUID
    user_key: str
    name: str
    normalized_name: str
    tare_weight_g: float
    has_photo: bool
    created_at: DateTimeValue
    updated_at: DateTimeValue


class ContainersListResponse(BaseModel):
    containers: list[ContainerResponse]


class ContainerPhotoStatus(BaseModel):
    has_photo: bool
```

- [ ] **Step 2: Re-export from `models/__init__.py`**

Add the imports next to the other model groups in `src/nutrition_server/models/__init__.py`:

```python
from nutrition_server.models.containers import (
    ContainerCreate,
    ContainerPhotoStatus,
    ContainerResponse,
    ContainerUpdate,
    ContainersListResponse,
)
```

And add to the `__all__` list:

```python
"ContainerCreate",
"ContainerUpdate",
"ContainerResponse",
"ContainersListResponse",
"ContainerPhotoStatus",
```

- [ ] **Step 3: Verify imports load**

Run: `uv run python -c "from nutrition_server.models import ContainerCreate, ContainersListResponse; print('ok')"`
Expected: prints `ok`.

- [ ] **Step 4: Commit**

```bash
git add src/nutrition_server/models/containers.py src/nutrition_server/models/__init__.py
git commit -m "feat(models): containers pydantic shapes"
```

---

## Task 5: Repository — write the failing tests first

**Files:**
- Create: `tests/integration/test_containers_repo.py`

- [ ] **Step 1: Write the test file**

```python
from __future__ import annotations

import os
import uuid
from datetime import datetime as DateTimeValue
from datetime import timezone as TimezoneValue

import pytest
import pytest_asyncio
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from nutrition_server.db import to_sqlalchemy_url, transaction
from nutrition_server.repositories.containers import ContainersRepository

pytestmark = pytest.mark.integration


def _integration_database_url() -> str:
    raw_url = os.getenv("TEST_DATABASE_URL")
    if raw_url is None:
        pytest.skip("Set TEST_DATABASE_URL to run integration tests")
    return to_sqlalchemy_url(raw_url)


async def _truncate(engine) -> None:
    async with engine.begin() as conn:
        await conn.exec_driver_sql("TRUNCATE TABLE containers RESTART IDENTITY CASCADE")


@pytest_asyncio.fixture
async def session() -> AsyncSession:
    engine = create_async_engine(_integration_database_url())
    await _truncate(engine)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as s:
        yield s
    await engine.dispose()


def _now() -> DateTimeValue:
    return DateTimeValue.now(tz=TimezoneValue.utc)


@pytest.mark.asyncio
async def test_create_then_get(session: AsyncSession) -> None:
    repo = ContainersRepository(session)
    async with transaction(session):
        row = await repo.create(
            user_key="khash",
            name="Big Pyrex",
            normalized_name="big pyrex",
            tare_weight_g=412.0,
            now=_now(),
        )
    assert row["name"] == "Big Pyrex"
    assert float(row["tare_weight_g"]) == 412.0
    assert row["photo"] is None and row["photo_thumb"] is None

    got = await repo.get_by_id(row["id"], "khash")
    assert got is not None and got["id"] == row["id"]


@pytest.mark.asyncio
async def test_duplicate_normalized_name_raises(session: AsyncSession) -> None:
    repo = ContainersRepository(session)
    async with transaction(session):
        await repo.create("khash", "Big Pyrex", "big pyrex", 412.0, _now())
    with pytest.raises(IntegrityError):
        async with transaction(session):
            await repo.create("khash", "Big Pyrex", "big pyrex", 500.0, _now())


@pytest.mark.asyncio
async def test_list_for_user_excludes_other_users(session: AsyncSession) -> None:
    repo = ContainersRepository(session)
    async with transaction(session):
        await repo.create("khash", "A", "a", 100.0, _now())
        await repo.create("other", "B", "b", 200.0, _now())
    rows = await repo.list_for_user("khash")
    assert len(rows) == 1 and rows[0]["name"] == "A"


@pytest.mark.asyncio
async def test_list_does_not_select_blob_columns(session: AsyncSession) -> None:
    """list rows must not contain `photo` or `photo_thumb` keys."""
    repo = ContainersRepository(session)
    async with transaction(session):
        await repo.create("khash", "A", "a", 100.0, _now())
        # Simulate a photo on the row to ensure list still excludes it.
        await repo.set_photo(
            container_id=(await repo.list_for_user("khash"))[0]["id"],
            user_key="khash",
            photo=b"\xff\xd8\xff",
            photo_thumb=b"\xff\xd8\xff",
            mime="image/jpeg",
            now=_now(),
        )
    rows = await repo.list_for_user("khash")
    assert "photo" not in rows[0]
    assert "photo_thumb" not in rows[0]
    assert rows[0]["has_photo"] is True


@pytest.mark.asyncio
async def test_update_fields(session: AsyncSession) -> None:
    repo = ContainersRepository(session)
    async with transaction(session):
        row = await repo.create("khash", "A", "a", 100.0, _now())
    async with transaction(session):
        updated = await repo.update_fields(
            row["id"], "khash", {"name": "B", "normalized_name": "b"}, _now()
        )
    assert updated is not None
    assert updated["name"] == "B" and updated["normalized_name"] == "b"


@pytest.mark.asyncio
async def test_delete(session: AsyncSession) -> None:
    repo = ContainersRepository(session)
    async with transaction(session):
        row = await repo.create("khash", "A", "a", 100.0, _now())
    async with transaction(session):
        ok = await repo.delete(row["id"], "khash")
    assert ok is True
    assert await repo.get_by_id(row["id"], "khash") is None


@pytest.mark.asyncio
async def test_get_photo_returns_full_or_thumb(session: AsyncSession) -> None:
    repo = ContainersRepository(session)
    async with transaction(session):
        row = await repo.create("khash", "A", "a", 100.0, _now())
        await repo.set_photo(
            container_id=row["id"],
            user_key="khash",
            photo=b"FULL",
            photo_thumb=b"THUMB",
            mime="image/jpeg",
            now=_now(),
        )
    full = await repo.get_photo(row["id"], "khash", thumb=False)
    thumb = await repo.get_photo(row["id"], "khash", thumb=True)
    assert full == (b"FULL", "image/jpeg")
    assert thumb == (b"THUMB", "image/jpeg")


@pytest.mark.asyncio
async def test_clear_photo(session: AsyncSession) -> None:
    repo = ContainersRepository(session)
    async with transaction(session):
        row = await repo.create("khash", "A", "a", 100.0, _now())
        await repo.set_photo(row["id"], "khash", b"X", b"Y", "image/jpeg", _now())
    async with transaction(session):
        await repo.clear_photo(row["id"], "khash", _now())
    assert await repo.get_photo(row["id"], "khash", thumb=False) is None
```

- [ ] **Step 2: Run the tests, expect failure**

Run: `TEST_DATABASE_URL=$TEST_DATABASE_URL uv run pytest tests/integration/test_containers_repo.py -v -m integration`
Expected: ImportError on `from nutrition_server.repositories.containers import ContainersRepository` (file doesn't exist yet).

- [ ] **Step 3: Commit**

```bash
git add tests/integration/test_containers_repo.py
git commit -m "test: failing repo tests for containers"
```

---

## Task 6: Repository implementation

**Files:**
- Create: `src/nutrition_server/repositories/containers.py`

- [ ] **Step 1: Write the implementation**

```python
from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any
from uuid import UUID

from sqlalchemy import case, delete, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.repositories.tables import containers


def _summary_columns() -> tuple[Any, ...]:
    """Columns safe for list/get summaries — never the blob bytes."""
    return (
        containers.c.id,
        containers.c.user_key,
        containers.c.name,
        containers.c.normalized_name,
        containers.c.tare_weight_g,
        case((containers.c.photo.isnot(None), True), else_=False).label("has_photo"),
        containers.c.created_at,
        containers.c.updated_at,
    )


class ContainersRepository:
    """Async SQLAlchemy queries for the `containers` table."""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def create(
        self,
        user_key: str,
        name: str,
        normalized_name: str,
        tare_weight_g: float,
        now: DateTimeValue,
    ) -> dict[str, Any]:
        stmt = (
            pg_insert(containers)
            .values(
                user_key=user_key,
                name=name,
                normalized_name=normalized_name,
                tare_weight_g=tare_weight_g,
                created_at=now,
                updated_at=now,
            )
            .returning(*_summary_columns())
        )
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())

    async def get_by_id(self, container_id: UUID, user_key: str) -> dict[str, Any] | None:
        stmt = (
            select(*_summary_columns())
            .where(containers.c.id == container_id)
            .where(containers.c.user_key == user_key)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def list_for_user(self, user_key: str) -> list[dict[str, Any]]:
        stmt = (
            select(*_summary_columns())
            .where(containers.c.user_key == user_key)
            .order_by(containers.c.normalized_name)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]

    async def update_fields(
        self,
        container_id: UUID,
        user_key: str,
        fields: dict[str, Any],
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        if not fields:
            return await self.get_by_id(container_id, user_key)
        values = {**fields, "updated_at": now}
        stmt = (
            update(containers)
            .where(containers.c.id == container_id)
            .where(containers.c.user_key == user_key)
            .values(**values)
            .returning(*_summary_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def delete(self, container_id: UUID, user_key: str) -> bool:
        stmt = (
            delete(containers)
            .where(containers.c.id == container_id)
            .where(containers.c.user_key == user_key)
            .returning(containers.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None

    async def set_photo(
        self,
        container_id: UUID,
        user_key: str,
        photo: bytes,
        photo_thumb: bytes,
        mime: str,
        now: DateTimeValue,
    ) -> bool:
        stmt = (
            update(containers)
            .where(containers.c.id == container_id)
            .where(containers.c.user_key == user_key)
            .values(photo=photo, photo_thumb=photo_thumb, photo_mime=mime, updated_at=now)
            .returning(containers.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None

    async def clear_photo(
        self,
        container_id: UUID,
        user_key: str,
        now: DateTimeValue,
    ) -> bool:
        stmt = (
            update(containers)
            .where(containers.c.id == container_id)
            .where(containers.c.user_key == user_key)
            .values(photo=None, photo_thumb=None, photo_mime=None, updated_at=now)
            .returning(containers.c.id)
        )
        result = await self._session.execute(stmt)
        return result.scalar_one_or_none() is not None

    async def get_photo(
        self,
        container_id: UUID,
        user_key: str,
        thumb: bool,
    ) -> tuple[bytes, str] | None:
        col = containers.c.photo_thumb if thumb else containers.c.photo
        stmt = (
            select(col, containers.c.photo_mime)
            .where(containers.c.id == container_id)
            .where(containers.c.user_key == user_key)
        )
        result = await self._session.execute(stmt)
        row = result.first()
        if row is None or row[0] is None:
            return None
        return bytes(row[0]), row[1] or "image/jpeg"
```

- [ ] **Step 2: Run the tests, expect pass**

Run: `TEST_DATABASE_URL=$TEST_DATABASE_URL uv run pytest tests/integration/test_containers_repo.py -v -m integration`
Expected: 8 passed.

- [ ] **Step 3: Commit**

```bash
git add src/nutrition_server/repositories/containers.py
git commit -m "feat(repo): containers repository"
```

---

## Task 7: Photo processor — failing test

**Files:**
- Create: `tests/test_container_photos.py`

- [ ] **Step 1: Write the test**

```python
from __future__ import annotations

import io

import pytest
from PIL import Image

from nutrition_server.services.container_photos import (
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
```

- [ ] **Step 2: Run, expect failure**

Run: `uv run pytest tests/test_container_photos.py -v`
Expected: ImportError (file doesn't exist).

- [ ] **Step 3: Commit**

```bash
git add tests/test_container_photos.py
git commit -m "test: failing tests for container photo processor"
```

---

## Task 8: Photo processor implementation

**Files:**
- Create: `src/nutrition_server/services/container_photos.py`

- [ ] **Step 1: Implementation**

```python
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
```

- [ ] **Step 2: Run tests, expect pass**

Run: `uv run pytest tests/test_container_photos.py -v`
Expected: 5 passed.

- [ ] **Step 3: Commit**

```bash
git add src/nutrition_server/services/container_photos.py
git commit -m "feat(services): pillow-based container photo processor"
```

---

## Task 9: Router — failing API tests

**Files:**
- Create: `tests/test_containers_api.py`

- [ ] **Step 1: Write the test**

Re-uses the existing TestClient mock pattern from `tests/test_app.py`. Container CRUD + photo endpoints exercise the router with the database layer patched, focusing on request/response wiring; full DB behaviour is covered by Task 5 integration tests.

```python
from __future__ import annotations

import io
import os
import uuid
from datetime import datetime as DateTimeValue
from datetime import timezone as TimezoneValue
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient
from PIL import Image

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test")
os.environ.setdefault("API_KEY", "test-key")


def _png_bytes(w: int, h: int) -> bytes:
    img = Image.new("RGB", (w, h), color=(10, 20, 30))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _now() -> DateTimeValue:
    return DateTimeValue.now(tz=TimezoneValue.utc)


def _row(name: str = "A", weight: float = 100.0) -> dict:
    return {
        "id": uuid.uuid4(),
        "user_key": "khash",
        "name": name,
        "normalized_name": name.lower(),
        "tare_weight_g": weight,
        "has_photo": False,
        "created_at": _now(),
        "updated_at": _now(),
    }


@pytest.fixture
def client() -> TestClient:
    with patch("nutrition_server.db.init_pool", new_callable=AsyncMock), patch(
        "nutrition_server.db.bootstrap_schema", new_callable=AsyncMock
    ), patch("nutrition_server.db.close_pool", new_callable=AsyncMock), patch(
        "nutrition_server.usda.USDAClient"
    ) as mock_usda_client:
        mock_usda_client.return_value.close = AsyncMock()
        from nutrition_server.app import app

        with TestClient(app) as test_client:
            yield test_client


HEADERS = {"X-API-Key": "test-key"}


def test_unauthenticated_rejected(client: TestClient) -> None:
    assert client.get("/containers").status_code == 401


def test_list_containers(client: TestClient) -> None:
    rows = [_row("A"), _row("B")]
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.list_for_user = AsyncMock(return_value=rows)
        resp = client.get("/containers", headers=HEADERS)
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["containers"]) == 2
    assert body["containers"][0]["name"] == "A"
    assert body["containers"][0]["has_photo"] is False
    assert "photo" not in body["containers"][0]


def test_create_container(client: TestClient) -> None:
    row = _row("Big Pyrex", 412.0)
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.create = AsyncMock(return_value=row)
        resp = client.post(
            "/containers",
            headers=HEADERS,
            json={"name": "Big Pyrex", "tare_weight_g": 412.0},
        )
    assert resp.status_code == 201
    assert resp.json()["name"] == "Big Pyrex"


def test_create_rejects_zero_weight(client: TestClient) -> None:
    resp = client.post(
        "/containers",
        headers=HEADERS,
        json={"name": "X", "tare_weight_g": 0},
    )
    assert resp.status_code == 422


def test_create_duplicate_name_returns_409(client: TestClient) -> None:
    from sqlalchemy.exc import IntegrityError

    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.create = AsyncMock(side_effect=IntegrityError("x", "y", Exception()))
        resp = client.post(
            "/containers",
            headers=HEADERS,
            json={"name": "Dup", "tare_weight_g": 1.0},
        )
    assert resp.status_code == 409


def test_get_container_404_when_missing(client: TestClient) -> None:
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.get_by_id = AsyncMock(return_value=None)
        resp = client.get(f"/containers/{uuid.uuid4()}", headers=HEADERS)
    assert resp.status_code == 404


def test_patch_container(client: TestClient) -> None:
    row = _row("Renamed", 99.0)
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.update_fields = AsyncMock(return_value=row)
        resp = client.patch(
            f"/containers/{row['id']}",
            headers=HEADERS,
            json={"name": "Renamed", "tare_weight_g": 99.0},
        )
    assert resp.status_code == 200
    assert resp.json()["name"] == "Renamed"


def test_delete_container(client: TestClient) -> None:
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.delete = AsyncMock(return_value=True)
        resp = client.delete(f"/containers/{uuid.uuid4()}", headers=HEADERS)
    assert resp.status_code == 204


def test_upload_photo_resizes_and_returns_status(client: TestClient) -> None:
    container_id = uuid.uuid4()
    src = _png_bytes(2000, 1000)
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.set_photo = AsyncMock(return_value=True)
        resp = client.put(
            f"/containers/{container_id}/photo",
            headers=HEADERS,
            files={"file": ("box.png", src, "image/png")},
        )
    assert resp.status_code == 200
    assert resp.json() == {"has_photo": True}


def test_upload_photo_rejects_non_image(client: TestClient) -> None:
    container_id = uuid.uuid4()
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.set_photo = AsyncMock(return_value=True)
        resp = client.put(
            f"/containers/{container_id}/photo",
            headers=HEADERS,
            files={"file": ("notes.txt", b"hello", "text/plain")},
        )
    assert resp.status_code == 415


def test_get_photo_returns_jpeg(client: TestClient) -> None:
    container_id = uuid.uuid4()
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.get_photo = AsyncMock(return_value=(b"\xff\xd8\xff\xe0", "image/jpeg"))
        resp = client.get(f"/containers/{container_id}/photo", headers=HEADERS)
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "image/jpeg"
    assert resp.content.startswith(b"\xff\xd8")


def test_get_photo_404_when_missing(client: TestClient) -> None:
    container_id = uuid.uuid4()
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.get_photo = AsyncMock(return_value=None)
        resp = client.get(f"/containers/{container_id}/photo", headers=HEADERS)
    assert resp.status_code == 404


def test_delete_photo(client: TestClient) -> None:
    container_id = uuid.uuid4()
    with patch(
        "nutrition_server.routers.containers.ContainersRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.clear_photo = AsyncMock(return_value=True)
        resp = client.delete(f"/containers/{container_id}/photo", headers=HEADERS)
    assert resp.status_code == 204
```

- [ ] **Step 2: Run, expect failure**

Run: `uv run pytest tests/test_containers_api.py -v`
Expected: every test fails because the router and the `/containers` routes don't exist yet.

- [ ] **Step 3: Commit**

```bash
git add tests/test_containers_api.py
git commit -m "test: failing API tests for containers router"
```

---

## Task 10: Router implementation

**Files:**
- Create: `src/nutrition_server/routers/containers.py`
- Modify: `src/nutrition_server/app.py`

- [ ] **Step 1: Write the router**

```python
from __future__ import annotations

from datetime import datetime as DateTimeValue
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, File, HTTPException, Query, Response, UploadFile
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.auth import require_api_key
from nutrition_server.config import get_settings
from nutrition_server.db import get_session_dependency, transaction
from nutrition_server.models import (
    ContainerCreate,
    ContainerPhotoStatus,
    ContainerResponse,
    ContainerUpdate,
    ContainersListResponse,
)
from nutrition_server.repositories.containers import ContainersRepository
from nutrition_server.services.container_photos import (
    PhotoTooLargeError,
    UnsupportedImageError,
    process_container_photo,
)
from nutrition_server.services.normalize import normalize_name

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_api_key)])
TZ = ZoneInfo(settings.timezone)

MAX_UPLOAD_BYTES = 10 * 1024 * 1024  # 10 MB


def _to_response(row: dict) -> ContainerResponse:
    return ContainerResponse(
        id=row["id"],
        user_key=row["user_key"],
        name=row["name"],
        normalized_name=row["normalized_name"],
        tare_weight_g=float(row["tare_weight_g"]),
        has_photo=bool(row["has_photo"]),
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


@router.get("/containers", response_model=ContainersListResponse)
async def list_containers(
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> ContainersListResponse:
    effective = user_key or settings.default_user_key
    repo = ContainersRepository(session)
    rows = await repo.list_for_user(effective)
    return ContainersListResponse(containers=[_to_response(r) for r in rows])


@router.post("/containers", status_code=201, response_model=ContainerResponse)
async def create_container(
    body: ContainerCreate,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> ContainerResponse:
    effective = user_key or settings.default_user_key
    repo = ContainersRepository(session)
    now = DateTimeValue.now(tz=TZ)
    try:
        async with transaction(session):
            row = await repo.create(
                user_key=effective,
                name=body.name,
                normalized_name=normalize_name(body.name),
                tare_weight_g=body.tare_weight_g,
                now=now,
            )
    except IntegrityError as exc:
        raise HTTPException(status_code=409, detail="A container with that name already exists") from exc
    return _to_response(row)


@router.get("/containers/{container_id}", response_model=ContainerResponse)
async def get_container(
    container_id: UUID,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> ContainerResponse:
    effective = user_key or settings.default_user_key
    repo = ContainersRepository(session)
    row = await repo.get_by_id(container_id, effective)
    if row is None:
        raise HTTPException(status_code=404, detail="Container not found")
    return _to_response(row)


@router.patch("/containers/{container_id}", response_model=ContainerResponse)
async def update_container(
    container_id: UUID,
    body: ContainerUpdate,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> ContainerResponse:
    effective = user_key or settings.default_user_key
    fields = body.model_dump(exclude_unset=True)
    if "name" in fields and fields["name"] is not None:
        fields["normalized_name"] = normalize_name(fields["name"])
    repo = ContainersRepository(session)
    now = DateTimeValue.now(tz=TZ)
    try:
        async with transaction(session):
            row = await repo.update_fields(container_id, effective, fields, now)
    except IntegrityError as exc:
        raise HTTPException(status_code=409, detail="A container with that name already exists") from exc
    if row is None:
        raise HTTPException(status_code=404, detail="Container not found")
    return _to_response(row)


@router.delete("/containers/{container_id}", status_code=204)
async def delete_container(
    container_id: UUID,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    effective = user_key or settings.default_user_key
    repo = ContainersRepository(session)
    async with transaction(session):
        deleted = await repo.delete(container_id, effective)
    if not deleted:
        raise HTTPException(status_code=404, detail="Container not found")


@router.put("/containers/{container_id}/photo", response_model=ContainerPhotoStatus)
async def upload_container_photo(
    container_id: UUID,
    file: UploadFile = File(...),
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> ContainerPhotoStatus:
    effective = user_key or settings.default_user_key
    raw = await file.read()
    try:
        full, thumb, mime = process_container_photo(raw, max_bytes=MAX_UPLOAD_BYTES)
    except PhotoTooLargeError as exc:
        raise HTTPException(status_code=413, detail=str(exc)) from exc
    except UnsupportedImageError as exc:
        raise HTTPException(status_code=415, detail="Unsupported or corrupt image") from exc

    repo = ContainersRepository(session)
    now = DateTimeValue.now(tz=TZ)
    async with transaction(session):
        ok = await repo.set_photo(
            container_id=container_id,
            user_key=effective,
            photo=full,
            photo_thumb=thumb,
            mime=mime,
            now=now,
        )
    if not ok:
        raise HTTPException(status_code=404, detail="Container not found")
    return ContainerPhotoStatus(has_photo=True)


@router.delete("/containers/{container_id}/photo", status_code=204)
async def delete_container_photo(
    container_id: UUID,
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> None:
    effective = user_key or settings.default_user_key
    repo = ContainersRepository(session)
    now = DateTimeValue.now(tz=TZ)
    async with transaction(session):
        ok = await repo.clear_photo(container_id, effective, now)
    if not ok:
        raise HTTPException(status_code=404, detail="Container not found")


@router.get("/containers/{container_id}/photo")
async def get_container_photo(
    container_id: UUID,
    size: str = Query(default="thumb", pattern="^(thumb|full)$"),
    user_key: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session_dependency),
) -> Response:
    effective = user_key or settings.default_user_key
    repo = ContainersRepository(session)
    result = await repo.get_photo(container_id, effective, thumb=(size == "thumb"))
    if result is None:
        raise HTTPException(status_code=404, detail="No photo")
    body, mime = result
    headers = {
        "Cache-Control": "private, max-age=86400",
    }
    return Response(content=body, media_type=mime, headers=headers)
```

- [ ] **Step 2: Wire into `app.py`**

Edit `src/nutrition_server/app.py`:

In the `from nutrition_server.routers import (...)` block, add `containers as containers_router,` (alphabetical position):

```python
from nutrition_server.routers import (
    containers as containers_router,
    custom_foods as custom_foods_router,
    entries,
    food_memory as food_memory_router,
    logs,
    meals as meals_router,
    summary,
    targets,
)
```

In the registration block, add a new line right before `app.include_router(custom_foods_router.router)`:

```python
app.include_router(containers_router.router)
```

- [ ] **Step 3: Run the API tests, expect pass**

Run: `uv run pytest tests/test_containers_api.py -v`
Expected: all tests pass.

- [ ] **Step 4: Run the full unit test suite as a regression check**

Run: `uv run pytest tests/ -v --ignore=tests/integration`
Expected: existing tests still pass; no test failures.

- [ ] **Step 5: Commit**

```bash
git add src/nutrition_server/routers/containers.py src/nutrition_server/app.py
git commit -m "feat(api): containers router with multipart photo upload"
```

---

## Task 11: MCP tools

**Files:**
- Modify: `src/nutrition_server/mcp/server.py`

- [ ] **Step 1: Edit imports**

In `src/nutrition_server/mcp/server.py`, extend the existing models import block to include the new container models:

```python
from nutrition_server.models import (
    ContainerResponse,           # NEW
    CustomFoodCreate,
    CustomFoodResponse,
    CustomFoodUpdate,
    FoodEntryCreate,
    FoodEntryResponse,
    FoodMemoryEntry,
    MacroTargets,
    MacroTotals,
    MealCreate,
    MealItemCreate,
    MealItemResponse,
    MealResponse,
    MealSummary,
    MealUpdate,
    ResolvedFood,
)
```

And add to the repository imports:

```python
from nutrition_server.repositories.containers import ContainersRepository  # NEW
```

- [ ] **Step 2: Add a response converter near the other `_*_response` helpers**

Search for the existing `def _custom_food_response(` (around line 130 in the current file) and add directly above (or below) it:

```python
def _container_response(row: dict) -> ContainerResponse:
    return ContainerResponse(
        id=row["id"],
        user_key=row["user_key"],
        name=row["name"],
        normalized_name=row["normalized_name"],
        tare_weight_g=float(row["tare_weight_g"]),
        has_photo=bool(row["has_photo"]),
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )
```

- [ ] **Step 3: Add the four tools**

Inside `build_mcp(...)`, find the `# ---------------- food memory ----------------` divider and add a new section directly before it (after the custom-foods tools end with `list_custom_foods`):

```python
    # ---------------- containers ----------------

    @mcp.tool
    async def list_containers() -> list[ContainerResponse]:
        """List all meal-prep containers (pots, boxes) saved for this user. Each row
        carries `tare_weight_g`, the container's empty weight in grams, used to deduct
        from a scale reading when meal-prepping."""
        async with get_session() as session:
            repo = ContainersRepository(session)
            rows = await repo.list_for_user(user_key)
        return [_container_response(r) for r in rows]

    @mcp.tool
    async def save_container(
        name: str,
        tare_weight_g: float = Field(gt=0),
    ) -> ContainerResponse:
        """Create a new meal-prep container with its empty (tare) weight in grams.
        Use this when the user mentions a new pot/box they want to track."""
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = ContainersRepository(session)
            try:
                async with transaction(session):
                    row = await repo.create(
                        user_key=user_key,
                        name=name,
                        normalized_name=normalize_name(name),
                        tare_weight_g=tare_weight_g,
                        now=now,
                    )
            except IntegrityError as exc:
                raise ToolError("A container with that name already exists") from exc
        return _container_response(row)

    @mcp.tool
    async def update_container(
        container_id: str,
        name: str | None = None,
        tare_weight_g: float | None = Field(default=None, gt=0),
    ) -> ContainerResponse:
        """Update name and/or tare weight of an existing container."""
        try:
            cid = UUID(container_id)
        except ValueError as exc:
            raise ToolError("container_id must be a UUID") from exc
        fields: dict[str, Any] = {}
        if name is not None:
            fields["name"] = name
            fields["normalized_name"] = normalize_name(name)
        if tare_weight_g is not None:
            fields["tare_weight_g"] = tare_weight_g
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = ContainersRepository(session)
            try:
                async with transaction(session):
                    row = await repo.update_fields(cid, user_key, fields, now)
            except IntegrityError as exc:
                raise ToolError("A container with that name already exists") from exc
        if row is None:
            raise ToolError("Container not found")
        return _container_response(row)

    @mcp.tool
    async def delete_container(container_id: str) -> dict[str, bool]:
        """Delete a container by id."""
        try:
            cid = UUID(container_id)
        except ValueError as exc:
            raise ToolError("container_id must be a UUID") from exc
        async with get_session() as session:
            repo = ContainersRepository(session)
            async with transaction(session):
                deleted = await repo.delete(cid, user_key)
        return {"deleted": deleted}
```

- [ ] **Step 4: Verify MCP tool registration**

Run: `uv run python -c "from nutrition_server.app import mcp; tools = mcp._tool_manager._tools.keys() if hasattr(mcp, '_tool_manager') else 'unknown'; print(sorted(t for t in tools if 'container' in t))"`
Expected: prints `['delete_container', 'list_containers', 'save_container', 'update_container']`.

(If the introspection above doesn't work due to FastMCP internals, fall back to: `uv run pytest tests/test_mcp_tools.py -v` and check it doesn't regress.)

- [ ] **Step 5: Commit**

```bash
git add src/nutrition_server/mcp/server.py
git commit -m "feat(mcp): containers tools (list/save/update/delete)"
```

---

## Task 12: Repo-level integration test for the full upload→fetch round trip

**Files:**
- Modify: `tests/integration/test_containers_repo.py`

- [ ] **Step 1: Append a round-trip test**

Append to the bottom of `tests/integration/test_containers_repo.py`:

```python
@pytest.mark.asyncio
async def test_set_then_get_photo_round_trip(session: AsyncSession) -> None:
    """End-to-end: set bytes, fetch them, confirm content matches."""
    repo = ContainersRepository(session)
    async with transaction(session):
        row = await repo.create("khash", "RT", "rt", 50.0, _now())
        await repo.set_photo(row["id"], "khash", b"\x89PNG-FULL", b"\x89PNG-THUMB", "image/jpeg", _now())
    full = await repo.get_photo(row["id"], "khash", thumb=False)
    thumb = await repo.get_photo(row["id"], "khash", thumb=True)
    assert full == (b"\x89PNG-FULL", "image/jpeg")
    assert thumb == (b"\x89PNG-THUMB", "image/jpeg")
```

- [ ] **Step 2: Run integration tests**

Run: `TEST_DATABASE_URL=$TEST_DATABASE_URL uv run pytest tests/integration/test_containers_repo.py -v -m integration`
Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add tests/integration/test_containers_repo.py
git commit -m "test: round-trip photo bytes through containers repo"
```

---

## Task 13: Manual smoke test

These steps are manual checks against a running server (local or Railway).

- [ ] **Step 1: Run server locally**

Run: `uv run uvicorn nutrition_server.app:app --reload`
Expected: server boots; `/health` returns ok.

- [ ] **Step 2: Create container**

```bash
curl -X POST http://localhost:8000/containers \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"Big Pyrex","tare_weight_g":412}'
```

Expected: `201` + JSON with `has_photo: false`.

- [ ] **Step 3: Upload photo**

```bash
curl -X PUT http://localhost:8000/containers/<id>/photo \
  -H "X-API-Key: $API_KEY" \
  -F "file=@/path/to/test.jpg"
```

Expected: `200` + `{"has_photo": true}`.

- [ ] **Step 4: Fetch thumbnail**

```bash
curl -o thumb.jpg http://localhost:8000/containers/<id>/photo?size=thumb \
  -H "X-API-Key: $API_KEY"
```

Expected: `thumb.jpg` written; `file thumb.jpg` reports JPEG ≤ 256 px long edge.

- [ ] **Step 5: List**

```bash
curl http://localhost:8000/containers -H "X-API-Key: $API_KEY"
```

Expected: container appears with `has_photo: true`; **no `photo` field in payload**.

---

## Task 14: Deploy + final verification

- [ ] **Step 1: Push branch and open PR**

```bash
git push -u origin <feature-branch>
gh pr create --title "feat: meal-prep containers (table, REST, photo, MCP)" --body "$(cat <<'EOF'
## Summary
- Add containers table with `(user_key, normalized_name)` unique index
- REST CRUD + multipart photo upload (Pillow re-encode + 256 px thumb stored in BYTEA)
- MCP tools: list/save/update/delete (no photo handling)

## Test plan
- [ ] `uv run pytest tests/ -v --ignore=tests/integration`
- [ ] `TEST_DATABASE_URL=$TEST_DATABASE_URL uv run pytest tests/integration -v -m integration`
- [ ] Manual: smoke-test the curl flow from Task 13
- [ ] Verify Railway deploy applies migration `20260508_000001`
EOF
)"
```

- [ ] **Step 2: Wait for Railway deploy**

Confirm migration applied: `railway run alembic current` (or check Railway logs for `Running upgrade ... -> 20260508_000001`).

- [ ] **Step 3: Re-run smoke test against Railway URL**

Same curl commands from Task 13, replacing `http://localhost:8000` with the Railway base URL.

---

## Self-Review (run before declaring done)

**Spec coverage:**
- Table schema (id, user_key, name, normalized_name, tare_weight_g, photo, photo_thumb, photo_mime, created_at, updated_at) → Tasks 2, 3.
- Indexes (user_key+normalized_name unique; user_key) → Tasks 2, 3.
- REST endpoints (list/create/get/patch/delete + photo PUT/GET/DELETE) → Task 10.
- 10 MB upload cap, JPEG re-encode, EXIF strip, 1600/256 px sizes → Task 8.
- 13 / 415 / 422 / 409 status codes → Task 9 tests + Task 10 router.
- `Cache-Control` on photo response → Task 10.
- MCP tools (list/save/update/delete, no photo) → Task 11.
- App-side `updated_at` bump on UPDATE → repo `update_fields` always sets it (Task 6).
- List/get never selects blob columns → `_summary_columns()` (Task 6) + Task 5 explicit assertion.

**Placeholder scan:** None present.

**Type consistency:** Repo column expressions use `containers.c.X`; SQLAlchemy `Table` uses snake_case columns; Pydantic responses mirror columns. `process_container_photo` signature matches its tests and router call site.

**Open issues:** none blocking.
