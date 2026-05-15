# Weight Tracking — Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `../specs/2026-05-13-weight-tracking-server-design.md`
**Companion iOS plan:** `../../../../diet-tracker-ios/docs/superpowers/plans/2026-05-13-weight-tracking-ios.md`

**Goal:** Add `weight_entries` storage + CRUD endpoints, a `target_weight_lb` column on `daily_target_profile`, and a `GET /calories_daily` range aggregate so the iOS client can compute weight-vs-calorie analytics.

**Architecture:** New `weight_entries` table with `(user_key, log_date)` uniqueness. Standard router → service → repository layering matching `entries`, `containers`, etc. Schema additions are idempotent (`IF NOT EXISTS` / `ADD COLUMN IF NOT EXISTS`) via `bootstrap_schema()`. No analytics math on this side.

**Tech Stack:** Python 3.11+, FastAPI, SQLAlchemy Core (async psycopg3), Pydantic v2, pytest with optional `integration` marker.

**Repo:** `diet-tracker-server`. This plan is independent and must be deployed before iOS work integrates.

---

## File Map

Creates:
- `src/diet_tracker_server/models/weight.py` — Pydantic DTOs (`WeightEntryResponse`, `WeightEntryUpsert`, `CaloriesDailyRow`).
- `src/diet_tracker_server/repositories/weight.py` — SQLAlchemy queries against `weight_entries`.
- `src/diet_tracker_server/services/weight_service.py` — kg→lb conversion, upsert orchestration, range validation.
- `src/diet_tracker_server/routers/weight.py` — `GET /weight`, `GET /weight/{date}`, `PUT /weight/{date}`, `DELETE /weight/{date}`.
- `tests/test_weight_routes.py` — TestClient unit tests.
- `tests/test_weight_service.py` — pure-function tests for conversion.
- `tests/test_calories_daily.py` — TestClient tests for the new summary endpoint.
- `tests/integration/test_weight_integration.py` — real-DB round-trip.

Modifies:
- `schema.sql` — append `weight_entries` block and `target_weight_lb` alter.
- `src/diet_tracker_server/repositories/tables.py` — add `weight_entries` `Table`, add `target_weight_lb` column to `daily_target_profile`.
- `src/diet_tracker_server/models/__init__.py` — re-export new models.
- `src/diet_tracker_server/models/common.py` — add `target_weight_lb: float | None` to `MacroTargets`.
- `src/diet_tracker_server/repositories/targets.py` — read/write the new column.
- `src/diet_tracker_server/routers/targets.py` — pass new field through.
- `src/diet_tracker_server/routers/summary.py` — add `GET /calories_daily`.
- `src/diet_tracker_server/services/summary_service.py` — add `daily_calorie_totals(...)`.
- `src/diet_tracker_server/app.py` — `include_router(weight_router.router)`.
- `tests/test_targets.py` (if exists) or extend whichever existing file covers `/targets` — verify `target_weight_lb` round-trip.

---

## Task 1: Add `weight_entries` Table + `target_weight_lb` column to SQLAlchemy metadata

**Files:**
- Modify: `src/diet_tracker_server/repositories/tables.py`

- [ ] **Step 1: Add `target_weight_lb` to `daily_target_profile`**

In `src/diet_tracker_server/repositories/tables.py`, modify the `daily_target_profile` table definition. Find this block:

```python
daily_target_profile = Table(
    "daily_target_profile",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")),
    Column("user_key", Text, nullable=False),
    Column("calories_target", Integer, nullable=False),
    Column("protein_g_target", Numeric, nullable=False),
    Column("carbs_g_target", Numeric, nullable=False),
    Column("fat_g_target", Numeric, nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Index("idx_daily_target_profile_user_key", "user_key", unique=True),
)
```

Insert a new column line right after `fat_g_target`:

```python
    Column("target_weight_lb", Numeric, nullable=True),
```

- [ ] **Step 2: Append `weight_entries` Table at the end of the file**

Append at the bottom of `src/diet_tracker_server/repositories/tables.py`:

```python
weight_entries = Table(
    "weight_entries",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")),
    Column("user_key", Text, nullable=False),
    Column("log_date", Date, nullable=False),
    Column("weight_lb", Numeric(6, 2), nullable=False),
    Column("source_unit", Text, nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    CheckConstraint("weight_lb > 0", name="weight_entries_weight_lb_check"),
    CheckConstraint("source_unit in ('lb','kg')", name="weight_entries_source_unit_check"),
    UniqueConstraint("user_key", "log_date", name="uq_weight_entries_user_key_log_date"),
    Index("idx_weight_entries_user_key_log_date", "user_key", "log_date"),
)
```

- [ ] **Step 3: Verify import**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && uv run python -c "from diet_tracker_server.repositories.tables import weight_entries, daily_target_profile; print(weight_entries.c.weight_lb.type, [c.name for c in daily_target_profile.c])"`

Expected: prints `NUMERIC(6, 2)` and a list including `'target_weight_lb'`.

- [ ] **Step 4: Commit**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server
git add src/diet_tracker_server/repositories/tables.py
git commit -m "feat(weight): add weight_entries table and target_weight_lb column"
```

---

## Task 2: Append schema.sql block

**Files:**
- Modify: `schema.sql`

- [ ] **Step 1: Append the schema additions at the end of `schema.sql`**

Add these blocks at the bottom of `/Users/khxsh/Documents/repos/projects/diet/diet-tracker-server/schema.sql`:

```sql
create table if not exists weight_entries (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  log_date date not null,
  weight_lb numeric(6,2) not null check (weight_lb > 0),
  source_unit text not null check (source_unit in ('lb','kg')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_key, log_date)
);
create index if not exists idx_weight_entries_user_key_log_date
  on weight_entries(user_key, log_date);

alter table daily_target_profile
  add column if not exists target_weight_lb numeric(6,2);
```

- [ ] **Step 2: Sanity-check the file**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && grep -c 'weight_entries' schema.sql`

Expected: prints `4` (table, two columns referenced indirectly via the index name, unique constraint inline — the actual count from these added lines is 3, plus index name match makes it 4). The exact number is less important than non-zero.

- [ ] **Step 3: Commit**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server
git add schema.sql
git commit -m "feat(weight): add weight_entries + target_weight_lb to schema.sql"
```

---

## Task 3: Create Pydantic DTOs

**Files:**
- Create: `src/diet_tracker_server/models/weight.py`
- Modify: `src/diet_tracker_server/models/common.py`
- Modify: `src/diet_tracker_server/models/__init__.py`

- [ ] **Step 1: Write the failing test for `WeightEntryUpsert` validation**

Create `tests/test_weight_models.py`:

```python
from __future__ import annotations

from decimal import Decimal

import pytest
from pydantic import ValidationError

from diet_tracker_server.models.weight import WeightEntryUpsert


def test_upsert_accepts_lb() -> None:
    body = WeightEntryUpsert(weight=Decimal("180.5"), unit="lb")
    assert body.weight == Decimal("180.5")
    assert body.unit == "lb"


def test_upsert_accepts_kg() -> None:
    body = WeightEntryUpsert(weight=Decimal("82"), unit="kg")
    assert body.unit == "kg"


def test_upsert_rejects_zero_weight() -> None:
    with pytest.raises(ValidationError):
        WeightEntryUpsert(weight=Decimal("0"), unit="lb")


def test_upsert_rejects_negative_weight() -> None:
    with pytest.raises(ValidationError):
        WeightEntryUpsert(weight=Decimal("-1"), unit="lb")


def test_upsert_rejects_invalid_unit() -> None:
    with pytest.raises(ValidationError):
        WeightEntryUpsert(weight=Decimal("180"), unit="oz")  # type: ignore[arg-type]
```

- [ ] **Step 2: Run the test, expect failures**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && uv run pytest tests/test_weight_models.py -v`

Expected: tests collect but fail with `ImportError` (no `weight.py`).

- [ ] **Step 3: Create `src/diet_tracker_server/models/weight.py`**

```python
from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from decimal import Decimal
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field


WeightUnit = Literal["lb", "kg"]


class WeightEntryResponse(BaseModel):
    id: UUID
    log_date: DateValue
    weight_lb: Decimal
    source_unit: WeightUnit
    created_at: DateTimeValue
    updated_at: DateTimeValue


class WeightEntryUpsert(BaseModel):
    weight: Decimal = Field(gt=0)
    unit: WeightUnit


class CaloriesDailyRow(BaseModel):
    log_date: DateValue
    calories: int
```

- [ ] **Step 4: Add `target_weight_lb` to `MacroTargets`**

Edit `src/diet_tracker_server/models/common.py`. Replace the file contents with:

```python
from __future__ import annotations

from pydantic import BaseModel, Field


class MacroTotals(BaseModel):
    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float


class MacroTargets(BaseModel):
    calories: int = Field(gt=0)
    protein_g: float = Field(ge=0)
    carbs_g: float = Field(ge=0)
    fat_g: float = Field(ge=0)
    target_weight_lb: float | None = Field(default=None, gt=0)
```

- [ ] **Step 5: Re-export from `models/__init__.py`**

Edit `src/diet_tracker_server/models/__init__.py`. Add imports near the other model imports (insert alphabetically — just after the `summary` import is fine):

```python
from diet_tracker_server.models.weight import (
    CaloriesDailyRow,
    WeightEntryResponse,
    WeightEntryUpsert,
    WeightUnit,
)
```

Append to the `__all__` list:

```python
    "CaloriesDailyRow",
    "WeightEntryResponse",
    "WeightEntryUpsert",
    "WeightUnit",
```

- [ ] **Step 6: Run all tests for the new models**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && uv run pytest tests/test_weight_models.py -v`

Expected: 5 tests pass.

- [ ] **Step 7: Commit**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server
git add src/diet_tracker_server/models/weight.py src/diet_tracker_server/models/common.py src/diet_tracker_server/models/__init__.py tests/test_weight_models.py
git commit -m "feat(weight): pydantic models for weight entries and target weight"
```

---

## Task 4: Weight service (kg→lb conversion)

**Files:**
- Create: `src/diet_tracker_server/services/weight_service.py`
- Create: `tests/test_weight_service.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/test_weight_service.py`:

```python
from __future__ import annotations

from decimal import Decimal

import pytest

from diet_tracker_server.services.weight_service import (
    MAX_RANGE_DAYS,
    normalize_to_lb,
    validate_range,
)


def test_normalize_passthrough_lb() -> None:
    assert normalize_to_lb(Decimal("180.50"), unit="lb") == Decimal("180.50")


def test_normalize_kg_to_lb() -> None:
    # 70 kg * 2.20462262 = 154.323... -> 154.32 at scale 2
    assert normalize_to_lb(Decimal("70"), unit="kg") == Decimal("154.32")


def test_normalize_kg_rounds_half_even() -> None:
    # 1 kg = 2.20462262 lb -> 2.20 (not 2.21) under ROUND_HALF_EVEN
    assert normalize_to_lb(Decimal("1"), unit="kg") == Decimal("2.20")


def test_validate_range_accepts_366_days() -> None:
    from datetime import date

    validate_range(date(2024, 1, 1), date(2024, 1, 1) + __import__("datetime").timedelta(days=366))


def test_validate_range_rejects_over_366() -> None:
    from datetime import date, timedelta

    with pytest.raises(ValueError):
        validate_range(date(2024, 1, 1), date(2024, 1, 1) + timedelta(days=367))


def test_validate_range_rejects_reversed() -> None:
    from datetime import date

    with pytest.raises(ValueError):
        validate_range(date(2024, 1, 2), date(2024, 1, 1))


def test_max_range_days_constant() -> None:
    assert MAX_RANGE_DAYS == 366
```

- [ ] **Step 2: Run tests, expect ImportError**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && uv run pytest tests/test_weight_service.py -v`

Expected: ImportError.

- [ ] **Step 3: Create `src/diet_tracker_server/services/weight_service.py`**

```python
from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from decimal import ROUND_HALF_EVEN, Decimal
from typing import Literal
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.models.weight import WeightEntryResponse
from diet_tracker_server.repositories.weight import WeightRepository


KG_TO_LB = Decimal("2.20462262")
MAX_RANGE_DAYS = 366
MAX_PAST_YEARS = 5


def normalize_to_lb(value: Decimal, unit: Literal["lb", "kg"]) -> Decimal:
    if unit == "lb":
        return value.quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)
    return (value * KG_TO_LB).quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)


def validate_range(from_date: DateValue, to_date: DateValue) -> None:
    if from_date > to_date:
        raise ValueError("from must be <= to")
    if (to_date - from_date).days > MAX_RANGE_DAYS:
        raise ValueError(f"range cannot exceed {MAX_RANGE_DAYS} days")


def validate_log_date(log_date: DateValue, today: DateValue) -> None:
    if log_date > today:
        raise ValueError("cannot log weight in the future")
    if (today - log_date).days > MAX_PAST_YEARS * 366:
        raise ValueError("date too far in past")


async def upsert_weight(
    session: AsyncSession,
    user_key: str,
    log_date: DateValue,
    weight: Decimal,
    unit: Literal["lb", "kg"],
    now: DateTimeValue,
) -> WeightEntryResponse:
    weight_lb = normalize_to_lb(weight, unit)
    repo = WeightRepository(session)
    row = await repo.upsert(
        user_key=user_key,
        log_date=log_date,
        weight_lb=weight_lb,
        source_unit=unit,
        updated_at=now,
    )
    return WeightEntryResponse(**row)


async def list_weight_range(
    session: AsyncSession,
    user_key: str,
    from_date: DateValue,
    to_date: DateValue,
) -> list[WeightEntryResponse]:
    validate_range(from_date, to_date)
    repo = WeightRepository(session)
    rows = await repo.list_range(user_key=user_key, from_date=from_date, to_date=to_date)
    return [WeightEntryResponse(**row) for row in rows]


async def get_weight(
    session: AsyncSession,
    user_key: str,
    log_date: DateValue,
) -> WeightEntryResponse | None:
    repo = WeightRepository(session)
    row = await repo.get_by_date(user_key=user_key, log_date=log_date)
    return WeightEntryResponse(**row) if row else None


async def delete_weight(
    session: AsyncSession,
    user_key: str,
    log_date: DateValue,
) -> bool:
    repo = WeightRepository(session)
    return await repo.delete(user_key=user_key, log_date=log_date)


# Unused parameter retained for symmetry with other services; placeholder to allow
# future async work without changing call sites.
_ = UUID
```

(Note: `WeightRepository` is created in the next task. The import will fail until then; the tests for *this service module* only exercise pure helpers, which don't import the repo. Run the targeted tests.)

- [ ] **Step 4: Adjust the test to avoid the repository import at collection time**

The pure-function tests don't need the async functions. Replace the import line at the top of `tests/test_weight_service.py` with a more targeted import:

```python
from diet_tracker_server.services.weight_service import (
    MAX_RANGE_DAYS,
    normalize_to_lb,
    validate_range,
)
```

(This is already what the test uses — confirm it does not import `upsert_weight` etc. Good.)

- [ ] **Step 5: Stub the repository import so the module loads**

The service imports `WeightRepository`. Create a stub `src/diet_tracker_server/repositories/weight.py` with just the class shell so import works; Task 5 fills it in:

```python
from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from decimal import Decimal
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession


class WeightRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def upsert(
        self,
        user_key: str,
        log_date: DateValue,
        weight_lb: Decimal,
        source_unit: str,
        updated_at: DateTimeValue,
    ) -> dict[str, Any]:
        raise NotImplementedError

    async def list_range(
        self,
        user_key: str,
        from_date: DateValue,
        to_date: DateValue,
    ) -> list[dict[str, Any]]:
        raise NotImplementedError

    async def get_by_date(
        self,
        user_key: str,
        log_date: DateValue,
    ) -> dict[str, Any] | None:
        raise NotImplementedError

    async def delete(
        self,
        user_key: str,
        log_date: DateValue,
    ) -> bool:
        raise NotImplementedError
```

- [ ] **Step 6: Run service tests**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && uv run pytest tests/test_weight_service.py -v`

Expected: 7 tests pass.

- [ ] **Step 7: Commit**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server
git add src/diet_tracker_server/services/weight_service.py src/diet_tracker_server/repositories/weight.py tests/test_weight_service.py
git commit -m "feat(weight): conversion + range validation service"
```

---

## Task 5: Weight repository

**Files:**
- Modify: `src/diet_tracker_server/repositories/weight.py`

- [ ] **Step 1: Replace `repositories/weight.py` with the full implementation**

```python
from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from decimal import Decimal
from typing import Any

from sqlalchemy import delete as sa_delete
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.repositories.tables import weight_entries


class WeightRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def upsert(
        self,
        user_key: str,
        log_date: DateValue,
        weight_lb: Decimal,
        source_unit: str,
        updated_at: DateTimeValue,
    ) -> dict[str, Any]:
        stmt = pg_insert(weight_entries).values(
            user_key=user_key,
            log_date=log_date,
            weight_lb=weight_lb,
            source_unit=source_unit,
            updated_at=updated_at,
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=[weight_entries.c.user_key, weight_entries.c.log_date],
            set_={
                "weight_lb": stmt.excluded.weight_lb,
                "source_unit": stmt.excluded.source_unit,
                "updated_at": updated_at,
            },
        ).returning(*weight_entries.c)
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        assert row is not None
        return dict(row)

    async def list_range(
        self,
        user_key: str,
        from_date: DateValue,
        to_date: DateValue,
    ) -> list[dict[str, Any]]:
        stmt = (
            select(*weight_entries.c)
            .where(weight_entries.c.user_key == user_key)
            .where(weight_entries.c.log_date >= from_date)
            .where(weight_entries.c.log_date <= to_date)
            .order_by(weight_entries.c.log_date.asc())
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings()]

    async def get_by_date(
        self,
        user_key: str,
        log_date: DateValue,
    ) -> dict[str, Any] | None:
        stmt = (
            select(*weight_entries.c)
            .where(weight_entries.c.user_key == user_key)
            .where(weight_entries.c.log_date == log_date)
            .limit(1)
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    async def delete(
        self,
        user_key: str,
        log_date: DateValue,
    ) -> bool:
        stmt = (
            sa_delete(weight_entries)
            .where(weight_entries.c.user_key == user_key)
            .where(weight_entries.c.log_date == log_date)
        )
        result = await self._session.execute(stmt)
        return result.rowcount > 0
```

- [ ] **Step 2: Verify it imports**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && uv run python -c "from diet_tracker_server.repositories.weight import WeightRepository; print('ok')"`

Expected: prints `ok`.

- [ ] **Step 3: Commit**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server
git add src/diet_tracker_server/repositories/weight.py
git commit -m "feat(weight): repository with upsert/list/get/delete"
```

---

## Task 6: Weight router

**Files:**
- Create: `src/diet_tracker_server/routers/weight.py`
- Modify: `src/diet_tracker_server/app.py`
- Create: `tests/test_weight_routes.py`

- [ ] **Step 1: Write the failing TestClient tests**

Create `tests/test_weight_routes.py`:

```python
from __future__ import annotations

import os
import uuid
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from datetime import timedelta as TimeDeltaValue
from datetime import timezone as TimezoneValue
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test")


def _now() -> DateTimeValue:
    return DateTimeValue.now(tz=TimezoneValue.utc)


def _row(log_date: DateValue, weight_lb: Decimal = Decimal("180.50")) -> dict:
    return {
        "id": uuid.uuid4(),
        "user_key": "khash",
        "log_date": log_date,
        "weight_lb": weight_lb,
        "source_unit": "lb",
        "created_at": _now(),
        "updated_at": _now(),
    }


@pytest.fixture
def client() -> TestClient:
    fut = _now() + TimeDeltaValue(days=7)
    session_repo = AsyncMock()
    session_repo.get.return_value = {"email": "khashzd@gmail.com", "expires_at": fut}
    session_repo.slide.return_value = 1
    session_repo.delete.return_value = 1
    fake_db_session = AsyncMock()
    db_ctx = AsyncMock()
    db_ctx.__aenter__.return_value = fake_db_session
    db_ctx.__aexit__.return_value = None

    with patch("diet_tracker_server.db.init_pool", new_callable=AsyncMock), patch(
        "diet_tracker_server.db.bootstrap_schema", new_callable=AsyncMock
    ), patch("diet_tracker_server.db.close_pool", new_callable=AsyncMock), patch(
        "diet_tracker_server.usda.USDAClient"
    ) as mock_usda_client, patch(
        "diet_tracker_server.auth.middleware.get_session", return_value=db_ctx
    ), patch(
        "diet_tracker_server.auth.middleware.SessionsRepository", return_value=session_repo
    ):
        mock_usda_client.return_value.close = AsyncMock()
        from diet_tracker_server.app import app
        from diet_tracker_server.db import get_session_dependency

        async def _fake_session_dep():
            session = MagicMock()
            session.begin = MagicMock()
            session.begin.return_value.__aenter__ = AsyncMock(return_value=session)
            session.begin.return_value.__aexit__ = AsyncMock(return_value=False)
            yield session

        app.dependency_overrides[get_session_dependency] = _fake_session_dep
        try:
            with TestClient(app) as test_client:
                yield test_client
        finally:
            app.dependency_overrides.pop(get_session_dependency, None)


HEADERS = {"Authorization": "Bearer tok"}


def test_unauthenticated_rejected(client: TestClient) -> None:
    assert client.get("/weight?from=2025-01-01&to=2025-01-02").status_code == 401


def test_put_weight_lb(client: TestClient) -> None:
    log_date = DateValue.today()
    row = _row(log_date)
    with patch(
        "diet_tracker_server.routers.weight.upsert_weight",
        new_callable=AsyncMock,
    ) as upsert:
        from diet_tracker_server.models.weight import WeightEntryResponse
        upsert.return_value = WeightEntryResponse(**row)
        resp = client.put(
            f"/weight/{log_date.isoformat()}",
            headers=HEADERS,
            json={"weight": "180.5", "unit": "lb"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["weight_lb"] == "180.50"
    assert body["source_unit"] == "lb"


def test_put_weight_kg(client: TestClient) -> None:
    log_date = DateValue.today()
    row = _row(log_date, weight_lb=Decimal("154.32"))
    row["source_unit"] = "kg"
    with patch(
        "diet_tracker_server.routers.weight.upsert_weight",
        new_callable=AsyncMock,
    ) as upsert:
        from diet_tracker_server.models.weight import WeightEntryResponse
        upsert.return_value = WeightEntryResponse(**row)
        resp = client.put(
            f"/weight/{log_date.isoformat()}",
            headers=HEADERS,
            json={"weight": "70", "unit": "kg"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["weight_lb"] == "154.32"
    assert body["source_unit"] == "kg"


def test_put_rejects_zero_weight(client: TestClient) -> None:
    resp = client.put(
        f"/weight/{DateValue.today().isoformat()}",
        headers=HEADERS,
        json={"weight": "0", "unit": "lb"},
    )
    assert resp.status_code == 422


def test_put_rejects_future_date(client: TestClient) -> None:
    future = (DateValue.today() + TimeDeltaValue(days=1)).isoformat()
    resp = client.put(
        f"/weight/{future}",
        headers=HEADERS,
        json={"weight": "180", "unit": "lb"},
    )
    assert resp.status_code == 400


def test_get_weight_404(client: TestClient) -> None:
    with patch(
        "diet_tracker_server.routers.weight.get_weight",
        new_callable=AsyncMock,
    ) as g:
        g.return_value = None
        resp = client.get(f"/weight/{DateValue.today().isoformat()}", headers=HEADERS)
    assert resp.status_code == 404


def test_get_weight_200(client: TestClient) -> None:
    row = _row(DateValue.today())
    with patch(
        "diet_tracker_server.routers.weight.get_weight",
        new_callable=AsyncMock,
    ) as g:
        from diet_tracker_server.models.weight import WeightEntryResponse
        g.return_value = WeightEntryResponse(**row)
        resp = client.get(f"/weight/{DateValue.today().isoformat()}", headers=HEADERS)
    assert resp.status_code == 200


def test_list_range(client: TestClient) -> None:
    today = DateValue.today()
    rows = [_row(today - TimeDeltaValue(days=2)), _row(today - TimeDeltaValue(days=1))]
    with patch(
        "diet_tracker_server.routers.weight.list_weight_range",
        new_callable=AsyncMock,
    ) as lst:
        from diet_tracker_server.models.weight import WeightEntryResponse
        lst.return_value = [WeightEntryResponse(**r) for r in rows]
        resp = client.get(
            f"/weight?from={(today - TimeDeltaValue(days=7)).isoformat()}&to={today.isoformat()}",
            headers=HEADERS,
        )
    assert resp.status_code == 200
    assert len(resp.json()) == 2


def test_list_range_rejects_inverted(client: TestClient) -> None:
    resp = client.get("/weight?from=2025-02-01&to=2025-01-01", headers=HEADERS)
    assert resp.status_code == 400


def test_list_range_rejects_oversize(client: TestClient) -> None:
    resp = client.get("/weight?from=2024-01-01&to=2025-12-31", headers=HEADERS)
    assert resp.status_code == 400


def test_delete_204(client: TestClient) -> None:
    with patch(
        "diet_tracker_server.routers.weight.delete_weight",
        new_callable=AsyncMock,
    ) as d:
        d.return_value = True
        resp = client.delete(f"/weight/{DateValue.today().isoformat()}", headers=HEADERS)
    assert resp.status_code == 204


def test_delete_404(client: TestClient) -> None:
    with patch(
        "diet_tracker_server.routers.weight.delete_weight",
        new_callable=AsyncMock,
    ) as d:
        d.return_value = False
        resp = client.delete(f"/weight/{DateValue.today().isoformat()}", headers=HEADERS)
    assert resp.status_code == 404
```

- [ ] **Step 2: Run tests, expect 401 only (route not registered yet)**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && uv run pytest tests/test_weight_routes.py -v`

Expected: many failures — `404 Not Found` from FastAPI since routes don't exist; some 422 / 400 by accident. That's fine; the next step makes them pass.

- [ ] **Step 3: Create `src/diet_tracker_server/routers/weight.py`**

```python
from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.auth import require_session
from diet_tracker_server.config import get_settings
from diet_tracker_server.db import get_session_dependency, transaction
from diet_tracker_server.models.weight import WeightEntryResponse, WeightEntryUpsert
from diet_tracker_server.services.weight_service import (
    delete_weight,
    get_weight,
    list_weight_range,
    upsert_weight,
    validate_log_date,
    validate_range,
)

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_session)])
TZ = ZoneInfo(settings.timezone)


@router.get("/weight", response_model=list[WeightEntryResponse])
async def list_weights(
    request: Request,
    from_: DateValue = Query(alias="from"),
    to: DateValue = Query(...),
    session: AsyncSession = Depends(get_session_dependency),
) -> list[WeightEntryResponse]:
    try:
        validate_range(from_, to)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return await list_weight_range(
        session=session,
        user_key=request.state.user_key,
        from_date=from_,
        to_date=to,
    )


@router.get("/weight/{log_date}", response_model=WeightEntryResponse)
async def get_weight_endpoint(
    request: Request,
    log_date: DateValue,
    session: AsyncSession = Depends(get_session_dependency),
) -> WeightEntryResponse:
    row = await get_weight(
        session=session,
        user_key=request.state.user_key,
        log_date=log_date,
    )
    if row is None:
        raise HTTPException(status_code=404, detail="no weight entry for date")
    return row


@router.put("/weight/{log_date}", response_model=WeightEntryResponse)
async def put_weight(
    request: Request,
    log_date: DateValue,
    body: WeightEntryUpsert,
    session: AsyncSession = Depends(get_session_dependency),
) -> WeightEntryResponse:
    today = DateTimeValue.now(tz=TZ).date()
    try:
        validate_log_date(log_date, today)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    now = DateTimeValue.now(tz=TZ)
    async with transaction(session):
        return await upsert_weight(
            session=session,
            user_key=request.state.user_key,
            log_date=log_date,
            weight=body.weight,
            unit=body.unit,
            now=now,
        )


@router.delete("/weight/{log_date}", status_code=204)
async def delete_weight_endpoint(
    request: Request,
    log_date: DateValue,
    session: AsyncSession = Depends(get_session_dependency),
) -> Response:
    async with transaction(session):
        deleted = await delete_weight(
            session=session,
            user_key=request.state.user_key,
            log_date=log_date,
        )
    if not deleted:
        raise HTTPException(status_code=404, detail="no weight entry for date")
    return Response(status_code=204)
```

- [ ] **Step 4: Register the router in `src/diet_tracker_server/app.py`**

Modify the import block at the top — add `weight as weight_router` to the multi-line import:

```python
from diet_tracker_server.routers import (
    containers as containers_router,
    custom_foods as custom_foods_router,
    entries,
    food_memory as food_memory_router,
    logs,
    meals as meals_router,
    summary,
    targets,
    weight as weight_router,
)
```

Then add an `include_router` line near the other ones (after `meals_router`):

```python
app.include_router(weight_router.router)
```

- [ ] **Step 5: Run the route tests**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && uv run pytest tests/test_weight_routes.py -v`

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server
git add src/diet_tracker_server/routers/weight.py src/diet_tracker_server/app.py tests/test_weight_routes.py
git commit -m "feat(weight): CRUD endpoints under /weight"
```

---

## Task 7: `GET /calories_daily` endpoint

**Files:**
- Modify: `src/diet_tracker_server/services/summary_service.py`
- Modify: `src/diet_tracker_server/routers/summary.py`
- Create: `tests/test_calories_daily.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/test_calories_daily.py`:

```python
from __future__ import annotations

import os
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from datetime import timedelta as TimeDeltaValue
from datetime import timezone as TimezoneValue
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test")


def _now() -> DateTimeValue:
    return DateTimeValue.now(tz=TimezoneValue.utc)


@pytest.fixture
def client() -> TestClient:
    fut = _now() + TimeDeltaValue(days=7)
    session_repo = AsyncMock()
    session_repo.get.return_value = {"email": "khashzd@gmail.com", "expires_at": fut}
    session_repo.slide.return_value = 1
    session_repo.delete.return_value = 1
    fake_db_session = AsyncMock()
    db_ctx = AsyncMock()
    db_ctx.__aenter__.return_value = fake_db_session
    db_ctx.__aexit__.return_value = None

    with patch("diet_tracker_server.db.init_pool", new_callable=AsyncMock), patch(
        "diet_tracker_server.db.bootstrap_schema", new_callable=AsyncMock
    ), patch("diet_tracker_server.db.close_pool", new_callable=AsyncMock), patch(
        "diet_tracker_server.usda.USDAClient"
    ) as mock_usda_client, patch(
        "diet_tracker_server.auth.middleware.get_session", return_value=db_ctx
    ), patch(
        "diet_tracker_server.auth.middleware.SessionsRepository", return_value=session_repo
    ):
        mock_usda_client.return_value.close = AsyncMock()
        from diet_tracker_server.app import app
        from diet_tracker_server.db import get_session_dependency

        async def _fake_session_dep():
            session = MagicMock()
            yield session

        app.dependency_overrides[get_session_dependency] = _fake_session_dep
        try:
            with TestClient(app) as test_client:
                yield test_client
        finally:
            app.dependency_overrides.pop(get_session_dependency, None)


HEADERS = {"Authorization": "Bearer tok"}


def test_calories_daily_happy(client: TestClient) -> None:
    today = DateValue.today()
    with patch(
        "diet_tracker_server.routers.summary.daily_calorie_totals",
        new_callable=AsyncMock,
    ) as fn:
        from diet_tracker_server.models.weight import CaloriesDailyRow
        fn.return_value = [
            CaloriesDailyRow(log_date=today - TimeDeltaValue(days=1), calories=1850),
            CaloriesDailyRow(log_date=today, calories=2100),
        ]
        resp = client.get(
            f"/calories_daily?from={(today - TimeDeltaValue(days=7)).isoformat()}&to={today.isoformat()}",
            headers=HEADERS,
        )
    assert resp.status_code == 200
    rows = resp.json()
    assert len(rows) == 2
    assert rows[0]["calories"] == 1850
    assert rows[1]["calories"] == 2100


def test_calories_daily_rejects_inverted(client: TestClient) -> None:
    resp = client.get("/calories_daily?from=2025-02-01&to=2025-01-01", headers=HEADERS)
    assert resp.status_code == 400


def test_calories_daily_rejects_oversize(client: TestClient) -> None:
    resp = client.get("/calories_daily?from=2024-01-01&to=2025-12-31", headers=HEADERS)
    assert resp.status_code == 400
```

- [ ] **Step 2: Run tests, expect failures**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && uv run pytest tests/test_calories_daily.py -v`

Expected: 404 / import errors.

- [ ] **Step 3: Add `daily_calorie_totals` to `services/summary_service.py`**

Append to `src/diet_tracker_server/services/summary_service.py`:

```python
from sqlalchemy import func as sa_func
from sqlalchemy import select

from diet_tracker_server.models.weight import CaloriesDailyRow
from diet_tracker_server.repositories.tables import daily_logs, food_entries


async def daily_calorie_totals(
    session: AsyncSession,
    user_key: str,
    from_date: DateValue,
    to_date: DateValue,
) -> list[CaloriesDailyRow]:
    stmt = (
        select(
            daily_logs.c.log_date.label("log_date"),
            sa_func.coalesce(sa_func.sum(food_entries.c.calories), 0).label("calories"),
        )
        .select_from(food_entries.join(daily_logs, daily_logs.c.id == food_entries.c.daily_log_id))
        .where(daily_logs.c.user_key == user_key)
        .where(daily_logs.c.log_date >= from_date)
        .where(daily_logs.c.log_date <= to_date)
        .group_by(daily_logs.c.log_date)
        .order_by(daily_logs.c.log_date.asc())
    )
    result = await session.execute(stmt)
    return [
        CaloriesDailyRow(log_date=row["log_date"], calories=int(row["calories"]))
        for row in result.mappings()
    ]
```

(If the file's existing imports already include `select`, leave them alone; the duplicate `from sqlalchemy import select` line will cause a lint warning. To stay clean, move the new imports to the top of the file alongside existing ones.)

- [ ] **Step 4: Add the route to `src/diet_tracker_server/routers/summary.py`**

Edit `src/diet_tracker_server/routers/summary.py` so the imports look like:

```python
from __future__ import annotations

from datetime import date as DateValue

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.auth import require_session
from diet_tracker_server.db import get_session_dependency
from diet_tracker_server.models import DailySummaryResponse
from diet_tracker_server.models.weight import CaloriesDailyRow
from diet_tracker_server.services.summary_service import (
    build_daily_summary,
    daily_calorie_totals,
)
from diet_tracker_server.services.weight_service import validate_range
```

After the existing `@router.get("/summary/{summary_date}", ...)` function, append:

```python
@router.get("/calories_daily", response_model=list[CaloriesDailyRow])
async def calories_daily(
    request: Request,
    from_: DateValue = Query(alias="from"),
    to: DateValue = Query(...),
    session: AsyncSession = Depends(get_session_dependency),
) -> list[CaloriesDailyRow]:
    try:
        validate_range(from_, to)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return await daily_calorie_totals(
        session=session,
        user_key=request.state.user_key,
        from_date=from_,
        to_date=to,
    )
```

- [ ] **Step 5: Run tests**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && uv run pytest tests/test_calories_daily.py -v`

Expected: all 3 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server
git add src/diet_tracker_server/services/summary_service.py src/diet_tracker_server/routers/summary.py tests/test_calories_daily.py
git commit -m "feat(weight): GET /calories_daily aggregate endpoint"
```

---

## Task 8: Plumb `target_weight_lb` through targets read/write

**Files:**
- Modify: `src/diet_tracker_server/repositories/targets.py`
- Modify: `src/diet_tracker_server/routers/targets.py`
- Create or modify: `tests/test_targets_weight.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_targets_weight.py`:

```python
from __future__ import annotations

import os
from datetime import datetime as DateTimeValue
from datetime import timedelta as TimeDeltaValue
from datetime import timezone as TimezoneValue
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test")


def _now() -> DateTimeValue:
    return DateTimeValue.now(tz=TimezoneValue.utc)


@pytest.fixture
def client() -> TestClient:
    fut = _now() + TimeDeltaValue(days=7)
    session_repo = AsyncMock()
    session_repo.get.return_value = {"email": "khashzd@gmail.com", "expires_at": fut}
    session_repo.slide.return_value = 1
    session_repo.delete.return_value = 1
    fake_db_session = AsyncMock()
    db_ctx = AsyncMock()
    db_ctx.__aenter__.return_value = fake_db_session
    db_ctx.__aexit__.return_value = None

    with patch("diet_tracker_server.db.init_pool", new_callable=AsyncMock), patch(
        "diet_tracker_server.db.bootstrap_schema", new_callable=AsyncMock
    ), patch("diet_tracker_server.db.close_pool", new_callable=AsyncMock), patch(
        "diet_tracker_server.usda.USDAClient"
    ) as mock_usda_client, patch(
        "diet_tracker_server.auth.middleware.get_session", return_value=db_ctx
    ), patch(
        "diet_tracker_server.auth.middleware.SessionsRepository", return_value=session_repo
    ):
        mock_usda_client.return_value.close = AsyncMock()
        from diet_tracker_server.app import app
        from diet_tracker_server.db import get_session_dependency

        async def _fake_session_dep():
            session = MagicMock()
            session.begin = MagicMock()
            session.begin.return_value.__aenter__ = AsyncMock(return_value=session)
            session.begin.return_value.__aexit__ = AsyncMock(return_value=False)
            yield session

        app.dependency_overrides[get_session_dependency] = _fake_session_dep
        try:
            with TestClient(app) as test_client:
                yield test_client
        finally:
            app.dependency_overrides.pop(get_session_dependency, None)


HEADERS = {"Authorization": "Bearer tok"}


def test_get_targets_includes_target_weight(client: TestClient) -> None:
    with patch(
        "diet_tracker_server.routers.targets.TargetsRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.get_target_profile = AsyncMock(
            return_value={
                "calories_target": 2000,
                "protein_g_target": 150.0,
                "carbs_g_target": 200.0,
                "fat_g_target": 70.0,
                "target_weight_lb": 175.0,
            }
        )
        resp = client.get("/targets", headers=HEADERS)
    assert resp.status_code == 200
    assert resp.json()["target_weight_lb"] == 175.0


def test_get_targets_null_target_weight(client: TestClient) -> None:
    with patch(
        "diet_tracker_server.routers.targets.TargetsRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.get_target_profile = AsyncMock(
            return_value={
                "calories_target": 2000,
                "protein_g_target": 150.0,
                "carbs_g_target": 200.0,
                "fat_g_target": 70.0,
                "target_weight_lb": None,
            }
        )
        resp = client.get("/targets", headers=HEADERS)
    assert resp.status_code == 200
    assert resp.json()["target_weight_lb"] is None


def test_put_targets_writes_target_weight(client: TestClient) -> None:
    with patch(
        "diet_tracker_server.routers.targets.TargetsRepository"
    ) as MockRepo:
        instance = MockRepo.return_value
        instance.upsert_targets = AsyncMock(return_value=None)
        resp = client.put(
            "/targets",
            headers=HEADERS,
            json={
                "calories": 2000,
                "protein_g": 150.0,
                "carbs_g": 200.0,
                "fat_g": 70.0,
                "target_weight_lb": 165.5,
            },
        )
    assert resp.status_code == 200
    instance.upsert_targets.assert_awaited_once()
    kwargs = instance.upsert_targets.await_args.kwargs
    assert kwargs["target_weight_lb"] == 165.5
```

- [ ] **Step 2: Run tests, expect failures**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && uv run pytest tests/test_targets_weight.py -v`

Expected: failures around missing `target_weight_lb` plumbing.

- [ ] **Step 3: Update `repositories/targets.py`**

Replace the file with:

```python
from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.repositories.tables import daily_target_profile


class TargetsRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get_target_profile(self, user_key: str) -> dict[str, Any] | None:
        stmt = select(*daily_target_profile.c).where(daily_target_profile.c.user_key == user_key).limit(1)
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        if row is None:
            return None
        return dict(row)

    async def upsert_targets(
        self,
        user_key: str,
        calories: int,
        protein_g: float,
        carbs_g: float,
        fat_g: float,
        target_weight_lb: float | None,
        updated_at: DateTimeValue,
    ) -> None:
        stmt = pg_insert(daily_target_profile).values(
            user_key=user_key,
            calories_target=calories,
            protein_g_target=protein_g,
            carbs_g_target=carbs_g,
            fat_g_target=fat_g,
            target_weight_lb=target_weight_lb,
            updated_at=updated_at,
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=[daily_target_profile.c.user_key],
            set_={
                "calories_target": stmt.excluded.calories_target,
                "protein_g_target": stmt.excluded.protein_g_target,
                "carbs_g_target": stmt.excluded.carbs_g_target,
                "fat_g_target": stmt.excluded.fat_g_target,
                "target_weight_lb": stmt.excluded.target_weight_lb,
                "updated_at": updated_at,
            },
        )
        await self._session.execute(stmt)
```

- [ ] **Step 4: Update `routers/targets.py`**

Replace the file with:

```python
from __future__ import annotations

from datetime import datetime as DateTimeValue
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.auth import require_session
from diet_tracker_server.config import get_settings
from diet_tracker_server.db import get_session_dependency, transaction
from diet_tracker_server.models import MacroTargets
from diet_tracker_server.repositories.targets import TargetsRepository

settings = get_settings()
router = APIRouter(dependencies=[Depends(require_session)])
TZ = ZoneInfo(settings.timezone)


@router.get("/targets", response_model=MacroTargets)
async def get_targets(
    request: Request,
    session: AsyncSession = Depends(get_session_dependency),
) -> MacroTargets:
    user_key = request.state.user_key
    repository = TargetsRepository(session)
    row = await repository.get_target_profile(user_key)
    if row is None:
        raise HTTPException(status_code=404, detail=f"No target profile for user {user_key}")
    return MacroTargets(
        calories=int(row["calories_target"]),
        protein_g=float(row["protein_g_target"]),
        carbs_g=float(row["carbs_g_target"]),
        fat_g=float(row["fat_g_target"]),
        target_weight_lb=float(row["target_weight_lb"]) if row.get("target_weight_lb") is not None else None,
    )


@router.put("/targets", response_model=MacroTargets)
async def update_targets(
    request: Request,
    body: MacroTargets,
    session: AsyncSession = Depends(get_session_dependency),
) -> MacroTargets:
    user_key = request.state.user_key
    now = DateTimeValue.now(tz=TZ)
    repository = TargetsRepository(session)
    async with transaction(session):
        await repository.upsert_targets(
            user_key=user_key,
            calories=body.calories,
            protein_g=body.protein_g,
            carbs_g=body.carbs_g,
            fat_g=body.fat_g,
            target_weight_lb=body.target_weight_lb,
            updated_at=now,
        )
    return body
```

- [ ] **Step 5: Run tests**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && uv run pytest tests/test_targets_weight.py tests/test_weight_routes.py tests/test_calories_daily.py -v`

Expected: all pass.

- [ ] **Step 6: Run full suite to catch regressions**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && uv run pytest tests/ -v --ignore=tests/integration`

Expected: every test passes. If a pre-existing `tests/test_targets.py` fails because it doesn't supply `target_weight_lb`, that's expected — the response now includes the new (null) field. Update those expectations only if they explicitly assert the absence of the field (a `pop`/`del` check). Just add a default `target_weight_lb=None` where needed.

- [ ] **Step 7: Commit**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server
git add src/diet_tracker_server/repositories/targets.py src/diet_tracker_server/routers/targets.py tests/test_targets_weight.py tests/
git commit -m "feat(weight): plumb target_weight_lb through targets read/write"
```

---

## Task 9: Integration tests (real Postgres)

**Files:**
- Create: `tests/integration/test_weight_integration.py`

- [ ] **Step 1: Write the integration test**

Create `tests/integration/test_weight_integration.py`:

```python
from __future__ import annotations

import os
import uuid
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from datetime import timedelta as TimeDeltaValue
from datetime import timezone as TimezoneValue
from decimal import Decimal

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server import db
from diet_tracker_server.repositories.weight import WeightRepository
from diet_tracker_server.services.weight_service import (
    delete_weight,
    get_weight,
    list_weight_range,
    upsert_weight,
)


pytestmark = pytest.mark.integration


@pytest.fixture
async def session() -> AsyncSession:
    test_db_url = os.environ["TEST_DATABASE_URL"]
    await db.init_pool(test_db_url)
    await db.bootstrap_schema()
    async with db.get_session() as s:
        await s.execute(text("truncate table weight_entries"))
        await s.commit()
        yield s
    await db.close_pool()


@pytest.mark.asyncio
async def test_upsert_then_get(session: AsyncSession) -> None:
    today = DateValue.today()
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    user_key = "test_user_" + uuid.uuid4().hex[:8]

    upserted = await upsert_weight(
        session=session,
        user_key=user_key,
        log_date=today,
        weight=Decimal("70"),
        unit="kg",
        now=now,
    )
    assert upserted.weight_lb == Decimal("154.32")
    assert upserted.source_unit == "kg"

    fetched = await get_weight(session=session, user_key=user_key, log_date=today)
    assert fetched is not None
    assert fetched.weight_lb == Decimal("154.32")


@pytest.mark.asyncio
async def test_upsert_replaces_same_date(session: AsyncSession) -> None:
    today = DateValue.today()
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    user_key = "test_user_" + uuid.uuid4().hex[:8]

    first = await upsert_weight(
        session=session, user_key=user_key, log_date=today,
        weight=Decimal("180"), unit="lb", now=now,
    )
    second = await upsert_weight(
        session=session, user_key=user_key, log_date=today,
        weight=Decimal("181.5"), unit="lb",
        now=now + TimeDeltaValue(seconds=1),
    )
    assert second.id == first.id
    assert second.weight_lb == Decimal("181.50")


@pytest.mark.asyncio
async def test_list_range(session: AsyncSession) -> None:
    today = DateValue.today()
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    user_key = "test_user_" + uuid.uuid4().hex[:8]
    for offset in (3, 2, 1, 0):
        await upsert_weight(
            session=session, user_key=user_key,
            log_date=today - TimeDeltaValue(days=offset),
            weight=Decimal("180") + Decimal(offset),
            unit="lb",
            now=now,
        )
    rows = await list_weight_range(
        session=session, user_key=user_key,
        from_date=today - TimeDeltaValue(days=3),
        to_date=today,
    )
    assert len(rows) == 4
    assert rows[0].log_date < rows[-1].log_date


@pytest.mark.asyncio
async def test_delete(session: AsyncSession) -> None:
    today = DateValue.today()
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    user_key = "test_user_" + uuid.uuid4().hex[:8]
    await upsert_weight(
        session=session, user_key=user_key, log_date=today,
        weight=Decimal("180"), unit="lb", now=now,
    )
    assert await delete_weight(session=session, user_key=user_key, log_date=today) is True
    assert await delete_weight(session=session, user_key=user_key, log_date=today) is False


@pytest.mark.asyncio
async def test_bootstrap_is_idempotent(session: AsyncSession) -> None:
    # If we get here, bootstrap already ran. Run it a second time.
    await db.bootstrap_schema()
```

- [ ] **Step 2: Run integration tests**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && TEST_DATABASE_URL=postgresql://localhost/diet_test uv run pytest -m integration tests/integration/test_weight_integration.py -v`

Expected: all 5 pass. If `TEST_DATABASE_URL` isn't available, the user should run this themselves before merge.

- [ ] **Step 3: Commit**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server
git add tests/integration/test_weight_integration.py
git commit -m "test(weight): integration tests for upsert/get/list/delete"
```

---

## Task 10: Smoke-run the server

- [ ] **Step 1: Boot the server**

Run: `cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-server && uv run uvicorn diet_tracker_server.app:app --port 8787 --reload`

In another shell, hit health and routes:

```bash
curl -s http://127.0.0.1:8787/health
# Expected: {"status":"ok"}

curl -s -X PUT 'http://127.0.0.1:8787/weight/2026-05-13?user_key=khash' \
  -H 'X-API-Key: dev' \
  -H 'Content-Type: application/json' \
  -d '{"weight":"180.5","unit":"lb"}'
# Expected: a JSON body with weight_lb=180.50, source_unit=lb
```

(The dev request format depends on the local auth setup. If running with legacy `?user_key=` + `X-API-Key=`, the call goes through `UserKeyGuardrailMiddleware` exemption configured in `app.py`. If running with Bearer sessions, use the OAuth flow.)

- [ ] **Step 2: Stop the server**

Hit Ctrl-C in the uvicorn shell.

- [ ] **Step 3: No commit needed — verification only.**

---

## Done

After Task 10:
- `weight_entries` table live, indexed on `(user_key, log_date)`.
- `target_weight_lb` column live on `daily_target_profile`.
- `/weight`, `/weight/{date}` (GET/PUT/DELETE), `/calories_daily` endpoints registered.
- `/targets` carries `target_weight_lb`.
- Unit and integration tests in place.

The iOS plan (`../../diet-tracker-ios/docs/superpowers/plans/2026-05-13-weight-tracking-ios.md`) consumes these endpoints.
