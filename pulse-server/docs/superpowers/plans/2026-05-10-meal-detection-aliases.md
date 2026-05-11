# Meal & Food Detection Aliases — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add LLM-driven aliasing so a single `food_memory` or `meals` row can match multiple user phrasings, with reject-on-collision semantics.

**Architecture:** Add `aliases text[]` columns to `food_memory` and `meals`; widen lookup `WHERE` clauses with `OR $1 = ANY(aliases)`; enforce cross-row uniqueness via a Postgres trigger (canonical_name + aliases form a per-user namespace). Four new MCP tools (`add_food_alias`, `remove_food_alias`, `add_meal_alias`, `remove_meal_alias`) plus optional `aliases` parameter on `remember_food` / `create_meal`.

**Tech Stack:** FastAPI + SQLAlchemy Core (async psycopg3) + Pydantic + FastMCP + Alembic + Postgres. Single-user scope today; cross-row collision checked at service layer plus enforced by trigger.

Spec: `docs/superpowers/specs/2026-05-10-meal-detection-aliases-design.md`.

---

## File Structure

**Server — create:**
- `alembic/versions/20260510_000001_add_food_memory_meals_aliases.py` — migration adding columns, GIN indexes, CHECK constraints, trigger function + triggers.
- `tests/integration/test_aliases.py` — integration tests for trigger, lookup widening, repo alias methods.

**Server — modify:**
- `schema.sql` — idempotent `do $body$ ... end $body$;` blocks adding the same columns/indexes/constraints/trigger for fresh bootstraps.
- `src/diet_tracker_server/repositories/tables.py` — add `aliases` `Column(ARRAY(Text))` to `food_memory` and `meals`.
- `src/diet_tracker_server/repositories/food_memory.py` — project `aliases` in `_row_columns()`; widen `get_by_name`; add `add_alias` / `remove_alias`.
- `src/diet_tracker_server/repositories/meals.py` — project `aliases` in `_meal_columns()` + `list_meals`; widen `get_meal_by_name`; add `add_alias` / `remove_alias`.
- `src/diet_tracker_server/services/food_memory_service.py` — add `assert_alias_available` collision pre-check + `normalize_alias_list` helper.
- `src/diet_tracker_server/services/meals_service.py` — same pair.
- `src/diet_tracker_server/models/food_memory.py` — `FoodMemoryEntry.aliases: list[str]`.
- `src/diet_tracker_server/models/meals.py` — `MealResponse.aliases`, `MealSummary.aliases`, `MealCreate.aliases`.
- `src/diet_tracker_server/mcp/server.py` — `_food_memory_entry` / `_meal_response` / `MealSummary` build include `aliases`; new tools; updated `WORKFLOW_INSTRUCTIONS`; optional `aliases` on `remember_food` + `create_meal`.
- `tests/test_mcp_tools.py` — add the four new tool names to the expected-tools set.

**iOS — modify:**
- `diet-tracker-ios/DietTracker/Models/Meal.swift` — add `aliases: [String]` (default `[]`) to `MealSummary` and `Meal`, decoded with `decodeIfPresent`.

---

## Task 1: Migration & schema — `aliases` columns + indexes + CHECK

**Files:**
- Create: `alembic/versions/20260510_000001_add_food_memory_meals_aliases.py`
- Modify: `schema.sql`

- [ ] **Step 1: Write the failing integration test** (verifies the column exists and accepts arrays)

Create `tests/integration/test_aliases.py`:

```python
from __future__ import annotations

import os
import uuid
from datetime import datetime as DateTimeValue
from datetime import timezone as TimezoneValue

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from diet_tracker_server.db import to_sqlalchemy_url

pytestmark = pytest.mark.integration


def _integration_database_url() -> str:
    raw_url = os.getenv("TEST_DATABASE_URL")
    if raw_url is None:
        pytest.skip("Set TEST_DATABASE_URL to run integration tests")
    return to_sqlalchemy_url(raw_url)


async def _truncate(engine) -> None:
    async with engine.begin() as conn:
        await conn.exec_driver_sql(
            "TRUNCATE TABLE food_entries, meal_items, meals, food_memory, custom_foods, daily_logs, daily_target_profile RESTART IDENTITY CASCADE"
        )


@pytest_asyncio.fixture(scope="session")
async def session_factory():
    engine = create_async_engine(_integration_database_url(), pool_pre_ping=True)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()


@pytest_asyncio.fixture(autouse=True)
async def clean_database(session_factory):
    await _truncate(session_factory.kw["bind"])
    yield
    await _truncate(session_factory.kw["bind"])


@pytest_asyncio.fixture
async def session(session_factory):
    async with session_factory() as s:
        yield s


@pytest.mark.asyncio
async def test_food_memory_has_aliases_column(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, aliases, created_at, updated_at) "
            "values (:uk, 'PB', 'pb', 1, 'PB', 'per_100g', 100, 1, 1, 1, ARRAY['peanut butter']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    row = (await session.execute(
        text("select aliases from food_memory where user_key = :uk"),
        {"uk": user_key},
    )).mappings().first()
    assert row is not None
    assert list(row["aliases"]) == ["peanut butter"]


@pytest.mark.asyncio
async def test_meals_has_aliases_column(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into meals (user_key, name, normalized_name, aliases, created_at, updated_at) "
            "values (:uk, 'Wrap', 'wrap', ARRAY['the wrap']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    row = (await session.execute(
        text("select aliases from meals where user_key = :uk"),
        {"uk": user_key},
    )).mappings().first()
    assert row is not None
    assert list(row["aliases"]) == ["the wrap"]


@pytest.mark.asyncio
async def test_food_memory_check_rejects_alias_equal_to_name(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    with pytest.raises(IntegrityError):
        await session.execute(
            text(
                "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, aliases, created_at, updated_at) "
                "values (:uk, 'PB', 'pb', 1, 'PB', 'per_100g', 100, 1, 1, 1, ARRAY['pb']::text[], :now, :now)"
            ),
            {"uk": user_key, "now": now},
        )
        await session.commit()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_aliases.py -v`
Expected: FAIL (column `aliases` does not exist).

- [ ] **Step 3: Write the Alembic migration**

Create `alembic/versions/20260510_000001_add_food_memory_meals_aliases.py`:

```python
"""Add aliases columns to food_memory and meals.

Revision ID: 20260510_000001
Revises: 20260506_000001
Create Date: 2026-05-10T00:00:00Z
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "20260510_000001"
down_revision = "20260506_000001"
branch_labels = None
depends_on = None


_TRIGGER_FN_TMPL = """
create or replace function {fn_name}() returns trigger
language plpgsql as $$
declare
  collision_name text;
begin
  if NEW.aliases is not null and array_length(NEW.aliases, 1) is not null then
    select normalized_name into collision_name from {table}
    where user_key = NEW.user_key
      and id is distinct from NEW.id
      and normalized_name = ANY(NEW.aliases)
    limit 1;
    if collision_name is not null then
      raise exception 'alias collides with canonical name %', collision_name
        using errcode = '23505';
    end if;

    select normalized_name into collision_name from {table}
    where user_key = NEW.user_key
      and id is distinct from NEW.id
      and aliases && NEW.aliases
    limit 1;
    if collision_name is not null then
      raise exception 'alias collides with alias of %', collision_name
        using errcode = '23505';
    end if;
  end if;

  select normalized_name into collision_name from {table}
  where user_key = NEW.user_key
    and id is distinct from NEW.id
    and NEW.normalized_name = ANY(aliases)
  limit 1;
  if collision_name is not null then
    raise exception 'name collides with alias of %', collision_name
      using errcode = '23505';
  end if;

  return NEW;
end;
$$;
"""


def upgrade() -> None:
    op.add_column(
        "food_memory",
        sa.Column(
            "aliases",
            postgresql.ARRAY(sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::text[]"),
        ),
    )
    op.add_column(
        "meals",
        sa.Column(
            "aliases",
            postgresql.ARRAY(sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::text[]"),
        ),
    )

    op.create_index(
        "idx_food_memory_aliases",
        "food_memory",
        ["aliases"],
        unique=False,
        postgresql_using="gin",
    )
    op.create_index(
        "idx_meals_aliases",
        "meals",
        ["aliases"],
        unique=False,
        postgresql_using="gin",
    )

    op.create_check_constraint(
        "food_memory_alias_not_self",
        "food_memory",
        "not (normalized_name = ANY(aliases))",
    )
    op.create_check_constraint(
        "meals_alias_not_self",
        "meals",
        "not (normalized_name = ANY(aliases))",
    )

    op.execute(_TRIGGER_FN_TMPL.format(
        fn_name="check_food_memory_alias_uniqueness",
        table="food_memory",
    ))
    op.execute(_TRIGGER_FN_TMPL.format(
        fn_name="check_meals_alias_uniqueness",
        table="meals",
    ))

    op.execute(
        "create trigger food_memory_alias_uniqueness "
        "before insert or update on food_memory "
        "for each row execute function check_food_memory_alias_uniqueness();"
    )
    op.execute(
        "create trigger meals_alias_uniqueness "
        "before insert or update on meals "
        "for each row execute function check_meals_alias_uniqueness();"
    )


def downgrade() -> None:
    op.execute("drop trigger if exists meals_alias_uniqueness on meals;")
    op.execute("drop trigger if exists food_memory_alias_uniqueness on food_memory;")
    op.execute("drop function if exists check_meals_alias_uniqueness();")
    op.execute("drop function if exists check_food_memory_alias_uniqueness();")
    op.drop_constraint("meals_alias_not_self", "meals", type_="check")
    op.drop_constraint("food_memory_alias_not_self", "food_memory", type_="check")
    op.drop_index("idx_meals_aliases", table_name="meals")
    op.drop_index("idx_food_memory_aliases", table_name="food_memory")
    op.drop_column("meals", "aliases")
    op.drop_column("food_memory", "aliases")
```

- [ ] **Step 4: Mirror the changes in `schema.sql`**

Append to `diet-tracker-server/schema.sql` (after the existing `do $body$` blocks at the end):

```sql
alter table food_memory add column if not exists aliases text[] not null default '{}'::text[];
alter table meals add column if not exists aliases text[] not null default '{}'::text[];

create index if not exists idx_food_memory_aliases on food_memory using gin (aliases);
create index if not exists idx_meals_aliases on meals using gin (aliases);

do $body$
begin
  if not exists (select 1 from pg_constraint where conname = 'food_memory_alias_not_self') then
    alter table food_memory add constraint food_memory_alias_not_self
      check (not (normalized_name = ANY(aliases)));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'meals_alias_not_self') then
    alter table meals add constraint meals_alias_not_self
      check (not (normalized_name = ANY(aliases)));
  end if;
end
$body$;

create or replace function check_food_memory_alias_uniqueness() returns trigger
language plpgsql as $$
declare
  collision_name text;
begin
  if NEW.aliases is not null and array_length(NEW.aliases, 1) is not null then
    select normalized_name into collision_name from food_memory
    where user_key = NEW.user_key and id is distinct from NEW.id
      and normalized_name = ANY(NEW.aliases)
    limit 1;
    if collision_name is not null then
      raise exception 'alias collides with canonical name %', collision_name using errcode = '23505';
    end if;
    select normalized_name into collision_name from food_memory
    where user_key = NEW.user_key and id is distinct from NEW.id
      and aliases && NEW.aliases
    limit 1;
    if collision_name is not null then
      raise exception 'alias collides with alias of %', collision_name using errcode = '23505';
    end if;
  end if;
  select normalized_name into collision_name from food_memory
  where user_key = NEW.user_key and id is distinct from NEW.id
    and NEW.normalized_name = ANY(aliases)
  limit 1;
  if collision_name is not null then
    raise exception 'name collides with alias of %', collision_name using errcode = '23505';
  end if;
  return NEW;
end;
$$;

create or replace function check_meals_alias_uniqueness() returns trigger
language plpgsql as $$
declare
  collision_name text;
begin
  if NEW.aliases is not null and array_length(NEW.aliases, 1) is not null then
    select normalized_name into collision_name from meals
    where user_key = NEW.user_key and id is distinct from NEW.id
      and normalized_name = ANY(NEW.aliases)
    limit 1;
    if collision_name is not null then
      raise exception 'alias collides with canonical name %', collision_name using errcode = '23505';
    end if;
    select normalized_name into collision_name from meals
    where user_key = NEW.user_key and id is distinct from NEW.id
      and aliases && NEW.aliases
    limit 1;
    if collision_name is not null then
      raise exception 'alias collides with alias of %', collision_name using errcode = '23505';
    end if;
  end if;
  select normalized_name into collision_name from meals
  where user_key = NEW.user_key and id is distinct from NEW.id
    and NEW.normalized_name = ANY(aliases)
  limit 1;
  if collision_name is not null then
    raise exception 'name collides with alias of %', collision_name using errcode = '23505';
  end if;
  return NEW;
end;
$$;

drop trigger if exists food_memory_alias_uniqueness on food_memory;
create trigger food_memory_alias_uniqueness
  before insert or update on food_memory
  for each row execute function check_food_memory_alias_uniqueness();

drop trigger if exists meals_alias_uniqueness on meals;
create trigger meals_alias_uniqueness
  before insert or update on meals
  for each row execute function check_meals_alias_uniqueness();
```

- [ ] **Step 5: Apply the migration and re-run the test**

Run:
```
uv run alembic upgrade head
TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_aliases.py -v
```
Expected: all three tests PASS.

- [ ] **Step 6: Add trigger-fires test for cross-row collisions**

Append to `tests/integration/test_aliases.py`:

```python
@pytest.mark.asyncio
async def test_food_memory_trigger_rejects_alias_equal_to_other_canonical(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, created_at, updated_at) "
            "values (:uk, 'Peanut Butter', 'peanut butter', 1, 'PB', 'per_100g', 100, 1, 1, 1, :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()
    with pytest.raises(IntegrityError):
        await session.execute(
            text(
                "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, aliases, created_at, updated_at) "
                "values (:uk, 'Almond Butter', 'almond butter', 2, 'AB', 'per_100g', 100, 1, 1, 1, ARRAY['peanut butter']::text[], :now, :now)"
            ),
            {"uk": user_key, "now": now},
        )
        await session.commit()


@pytest.mark.asyncio
async def test_meals_trigger_rejects_alias_overlap(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into meals (user_key, name, normalized_name, aliases, created_at, updated_at) "
            "values (:uk, 'Wrap A', 'wrap a', ARRAY['the wrap']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()
    with pytest.raises(IntegrityError):
        await session.execute(
            text(
                "insert into meals (user_key, name, normalized_name, aliases, created_at, updated_at) "
                "values (:uk, 'Wrap B', 'wrap b', ARRAY['the wrap']::text[], :now, :now)"
            ),
            {"uk": user_key, "now": now},
        )
        await session.commit()
```

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_aliases.py -v`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add alembic/versions/20260510_000001_add_food_memory_meals_aliases.py schema.sql tests/integration/test_aliases.py
git commit -m "feat(db): add aliases columns + uniqueness trigger to food_memory, meals"
```

---

## Task 2: Update `tables.py` — SQLAlchemy column definitions

**Files:**
- Modify: `src/diet_tracker_server/repositories/tables.py`

- [ ] **Step 1: Write the failing unit test**

Add to `tests/test_models.py` (or new `tests/test_tables.py`):

```python
def test_food_memory_table_has_aliases_column() -> None:
    from diet_tracker_server.repositories.tables import food_memory, meals
    assert "aliases" in food_memory.c
    assert "aliases" in meals.c
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `uv run pytest tests/test_models.py -v -k aliases_column`
Expected: FAIL with KeyError or AttributeError.

- [ ] **Step 3: Add the columns**

In `src/diet_tracker_server/repositories/tables.py`, update the import line to include `ARRAY`:

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
    MetaData,
    Numeric,
    Table,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import ARRAY, UUID
```

In the `food_memory` Table definition, before the `CheckConstraint("(usda_fdc_id is not null ...")` line, add:

```python
    Column("aliases", ARRAY(Text), nullable=False, server_default=text("'{}'::text[]")),
```

In the `meals` Table definition, before `Index("idx_meals_user_key_name", ...)`, add the same column line.

- [ ] **Step 4: Run the test to verify it passes**

Run: `uv run pytest tests/test_models.py -v -k aliases_column`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/diet_tracker_server/repositories/tables.py tests/test_models.py
git commit -m "feat(db): add aliases columns to food_memory/meals SQLAlchemy tables"
```

---

## Task 3: Pydantic models — `aliases` field on responses + writes

**Files:**
- Modify: `src/diet_tracker_server/models/food_memory.py`
- Modify: `src/diet_tracker_server/models/meals.py`

- [ ] **Step 1: Write the failing test**

Add to `tests/test_models.py`:

```python
def test_food_memory_entry_aliases_defaults_to_empty_list() -> None:
    from datetime import datetime
    from uuid import uuid4
    from diet_tracker_server.models import FoodMemoryEntry

    entry = FoodMemoryEntry(
        id=uuid4(),
        user_key="khash",
        name="PB",
        normalized_name="pb",
        usda_fdc_id=1,
        usda_description="PB",
        basis="per_100g",
        calories=100,
        protein_g=1.0,
        carbs_g=1.0,
        fat_g=1.0,
        created_at=datetime.now(),
        updated_at=datetime.now(),
    )
    assert entry.aliases == []


def test_meal_summary_aliases_defaults_to_empty_list() -> None:
    from uuid import uuid4
    from diet_tracker_server.models import MealSummary

    summary = MealSummary(
        id=uuid4(),
        name="Wrap",
        normalized_name="wrap",
        notes=None,
        item_count=0,
    )
    assert summary.aliases == []
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `uv run pytest tests/test_models.py -v -k aliases_defaults`
Expected: FAIL with ValidationError or AttributeError.

- [ ] **Step 3: Add `aliases` fields**

In `src/diet_tracker_server/models/food_memory.py`, modify `FoodMemoryEntry`:

```python
class FoodMemoryEntry(BaseModel):
    id: UUID
    user_key: str
    name: str
    normalized_name: str
    usda_fdc_id: int | None = None
    usda_description: str | None = None
    custom_food_id: UUID | None = None
    basis: CustomFoodBasis | None = None
    serving_size: float | None = None
    serving_size_unit: str | None = None
    calories: int | None = None
    protein_g: float | None = None
    carbs_g: float | None = None
    fat_g: float | None = None
    aliases: list[str] = Field(default_factory=list)
    created_at: DateTimeValue
    updated_at: DateTimeValue
```

In `src/diet_tracker_server/models/meals.py`, add `aliases: list[str] = Field(default_factory=list)` to `MealResponse`, `MealSummary`, and `MealCreate`:

```python
class MealCreate(BaseModel):
    name: str
    notes: str | None = None
    items: list[MealItemCreate] = Field(default_factory=list)
    aliases: list[str] = Field(default_factory=list)


class MealResponse(BaseModel):
    id: UUID
    user_key: str
    name: str
    normalized_name: str
    notes: str | None
    aliases: list[str] = Field(default_factory=list)
    created_at: DateTimeValue
    updated_at: DateTimeValue
    items: list[MealItemResponse] = Field(default_factory=list)


class MealSummary(BaseModel):
    id: UUID
    name: str
    normalized_name: str
    notes: str | None
    aliases: list[str] = Field(default_factory=list)
    item_count: int
    total_calories: int = 0
    total_protein_g: float = 0.0
    total_carbs_g: float = 0.0
    total_fat_g: float = 0.0
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `uv run pytest tests/test_models.py -v -k aliases_defaults`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/diet_tracker_server/models/food_memory.py src/diet_tracker_server/models/meals.py tests/test_models.py
git commit -m "feat(models): add aliases field to FoodMemoryEntry, Meal{Response,Summary,Create}"
```

---

## Task 4: `food_memory` repo — project aliases + widen lookup

**Files:**
- Modify: `src/diet_tracker_server/repositories/food_memory.py`
- Test: `tests/integration/test_aliases.py`

- [ ] **Step 1: Write the failing integration test**

Append to `tests/integration/test_aliases.py`:

```python
from diet_tracker_server.repositories.food_memory import FoodMemoryRepository


@pytest.mark.asyncio
async def test_food_memory_get_by_name_matches_alias(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, aliases, created_at, updated_at) "
            "values (:uk, 'Peanut Butter', 'peanut butter', 1, 'PB', 'per_100g', 100, 1, 1, 1, ARRAY['pb', 'pbs']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    repo = FoodMemoryRepository(session)
    row = await repo.get_by_name(user_key=user_key, normalized_name="pb")
    assert row is not None
    assert row["normalized_name"] == "peanut butter"
    assert list(row["aliases"]) == ["pb", "pbs"]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_aliases.py::test_food_memory_get_by_name_matches_alias -v`
Expected: FAIL — `get_by_name` returns None (currently does exact match only).

- [ ] **Step 3: Update `_row_columns` and `get_by_name`**

In `src/diet_tracker_server/repositories/food_memory.py`, modify `_row_columns` to include `aliases`:

```python
def _row_columns() -> tuple[Any, ...]:
    return (
        food_memory.c.id,
        food_memory.c.user_key,
        food_memory.c.name,
        food_memory.c.normalized_name,
        food_memory.c.usda_fdc_id,
        food_memory.c.usda_description,
        food_memory.c.custom_food_id,
        food_memory.c.basis,
        food_memory.c.serving_size,
        food_memory.c.serving_size_unit,
        food_memory.c.calories,
        food_memory.c.protein_g,
        food_memory.c.carbs_g,
        food_memory.c.fat_g,
        food_memory.c.aliases,
        food_memory.c.created_at,
        food_memory.c.updated_at,
    )
```

Update the import at the top of the file to add `or_`:

```python
from sqlalchemy import delete, or_, select
```

Modify `get_by_name` to widen the WHERE clause:

```python
    async def get_by_name(self, user_key: str, normalized_name: str) -> dict[str, Any] | None:
        stmt = (
            select(
                *_row_columns(),
                custom_foods.c.id.label("cf_id"),
                custom_foods.c.user_key.label("cf_user_key"),
                custom_foods.c.name.label("cf_name"),
                custom_foods.c.normalized_name.label("cf_normalized_name"),
                custom_foods.c.basis.label("cf_basis"),
                custom_foods.c.serving_size.label("cf_serving_size"),
                custom_foods.c.serving_size_unit.label("cf_serving_size_unit"),
                custom_foods.c.calories.label("cf_calories"),
                custom_foods.c.protein_g.label("cf_protein_g"),
                custom_foods.c.carbs_g.label("cf_carbs_g"),
                custom_foods.c.fat_g.label("cf_fat_g"),
                custom_foods.c.source.label("cf_source"),
                custom_foods.c.notes.label("cf_notes"),
                custom_foods.c.created_at.label("cf_created_at"),
                custom_foods.c.updated_at.label("cf_updated_at"),
            )
            .select_from(food_memory.outerjoin(custom_foods, custom_foods.c.id == food_memory.c.custom_food_id))
            .where(food_memory.c.user_key == user_key)
            .where(
                or_(
                    food_memory.c.normalized_name == normalized_name,
                    food_memory.c.aliases.any(normalized_name),
                )
            )
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None
```

Note: SQLAlchemy's `ARRAY.any(value)` compiles to `value = ANY(column)` which is index-friendly with GIN.

- [ ] **Step 4: Run the test to verify it passes**

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_aliases.py::test_food_memory_get_by_name_matches_alias -v`
Expected: PASS.

- [ ] **Step 5: Verify the existing exact-match path still works**

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration -v`
Expected: all existing integration tests PASS.

- [ ] **Step 6: Commit**

```bash
git add src/diet_tracker_server/repositories/food_memory.py tests/integration/test_aliases.py
git commit -m "feat(repo): widen food_memory lookup to match aliases"
```

---

## Task 5: `meals` repo — project aliases + widen lookup + include in list

**Files:**
- Modify: `src/diet_tracker_server/repositories/meals.py`
- Test: `tests/integration/test_aliases.py`

- [ ] **Step 1: Write the failing integration test**

Append to `tests/integration/test_aliases.py`:

```python
from diet_tracker_server.repositories.meals import MealsRepository


@pytest.mark.asyncio
async def test_meals_get_by_name_matches_alias(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into meals (user_key, name, normalized_name, aliases, created_at, updated_at) "
            "values (:uk, 'Buffalo Chicken Wrap', 'buffalo chicken wrap', ARRAY['the wrap']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    repo = MealsRepository(session)
    row = await repo.get_meal_by_name(user_key=user_key, normalized_name="the wrap")
    assert row is not None
    assert row["normalized_name"] == "buffalo chicken wrap"
    assert list(row["aliases"]) == ["the wrap"]


@pytest.mark.asyncio
async def test_meals_list_includes_aliases(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into meals (user_key, name, normalized_name, aliases, created_at, updated_at) "
            "values (:uk, 'Wrap', 'wrap', ARRAY['the wrap', 'lunch wrap']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    repo = MealsRepository(session)
    rows = await repo.list_meals(user_key=user_key)
    assert len(rows) == 1
    assert list(rows[0]["aliases"]) == ["the wrap", "lunch wrap"]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_aliases.py -v -k "meals_get_by_name or meals_list_includes"`
Expected: FAIL.

- [ ] **Step 3: Update `_meal_columns`, `get_meal_by_name`, `list_meals`**

In `src/diet_tracker_server/repositories/meals.py`, update import:

```python
from sqlalchemy import Integer, cast, delete, func, or_, select, update
```

Update `_meal_columns`:

```python
def _meal_columns() -> tuple[Any, ...]:
    return (
        meals.c.id,
        meals.c.user_key,
        meals.c.name,
        meals.c.normalized_name,
        meals.c.notes,
        meals.c.aliases,
        meals.c.created_at,
        meals.c.updated_at,
    )
```

Update `get_meal_by_name`:

```python
    async def get_meal_by_name(self, user_key: str, normalized_name: str) -> dict[str, Any] | None:
        stmt = (
            select(*_meal_columns())
            .where(meals.c.user_key == user_key)
            .where(
                or_(
                    meals.c.normalized_name == normalized_name,
                    meals.c.aliases.any(normalized_name),
                )
            )
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None
```

Update `list_meals` — add `meals.c.aliases` to select columns and group_by:

```python
    async def list_meals(self, user_key: str) -> list[dict[str, Any]]:
        stmt = (
            select(
                meals.c.id,
                meals.c.name,
                meals.c.normalized_name,
                meals.c.notes,
                meals.c.aliases,
                func.count(meal_items.c.id).label("item_count"),
                cast(func.coalesce(func.sum(meal_items.c.calories), 0), Integer).label("total_calories"),
                func.coalesce(func.sum(meal_items.c.protein_g), 0).label("total_protein_g"),
                func.coalesce(func.sum(meal_items.c.carbs_g), 0).label("total_carbs_g"),
                func.coalesce(func.sum(meal_items.c.fat_g), 0).label("total_fat_g"),
            )
            .select_from(meals.outerjoin(meal_items, meal_items.c.meal_id == meals.c.id))
            .where(meals.c.user_key == user_key)
            .group_by(meals.c.id, meals.c.name, meals.c.normalized_name, meals.c.notes, meals.c.aliases)
            .order_by(meals.c.normalized_name)
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_aliases.py -v -k "meals_get_by_name or meals_list_includes"`
Expected: PASS.

- [ ] **Step 5: Verify existing tests still pass**

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration -v`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add src/diet_tracker_server/repositories/meals.py tests/integration/test_aliases.py
git commit -m "feat(repo): widen meals lookup to match aliases; include in list_meals"
```

---

## Task 6: `food_memory` repo — `add_alias` / `remove_alias`

**Files:**
- Modify: `src/diet_tracker_server/repositories/food_memory.py`
- Test: `tests/integration/test_aliases.py`

- [ ] **Step 1: Write the failing integration tests**

Append to `tests/integration/test_aliases.py`:

```python
@pytest.mark.asyncio
async def test_food_memory_add_alias_appends(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, created_at, updated_at) "
            "values (:uk, 'Peanut Butter', 'peanut butter', 1, 'PB', 'per_100g', 100, 1, 1, 1, :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    repo = FoodMemoryRepository(session)
    updated = await repo.add_alias(
        user_key=user_key, normalized_name="peanut butter", alias="pb", now=now,
    )
    await session.commit()
    assert updated is not None
    assert list(updated["aliases"]) == ["pb"]


@pytest.mark.asyncio
async def test_food_memory_add_alias_idempotent(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, aliases, created_at, updated_at) "
            "values (:uk, 'PB', 'peanut butter', 1, 'PB', 'per_100g', 100, 1, 1, 1, ARRAY['pb']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    repo = FoodMemoryRepository(session)
    updated = await repo.add_alias(
        user_key=user_key, normalized_name="peanut butter", alias="pb", now=now,
    )
    await session.commit()
    assert list(updated["aliases"]) == ["pb"]


@pytest.mark.asyncio
async def test_food_memory_remove_alias(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, aliases, created_at, updated_at) "
            "values (:uk, 'PB', 'peanut butter', 1, 'PB', 'per_100g', 100, 1, 1, 1, ARRAY['pb', 'pbs']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    repo = FoodMemoryRepository(session)
    updated = await repo.remove_alias(
        user_key=user_key, normalized_name="peanut butter", alias="pb", now=now,
    )
    await session.commit()
    assert list(updated["aliases"]) == ["pbs"]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_aliases.py -v -k "food_memory_add_alias or food_memory_remove_alias"`
Expected: FAIL with AttributeError.

- [ ] **Step 3: Implement `add_alias` and `remove_alias`**

Add to the top of `src/diet_tracker_server/repositories/food_memory.py` imports:

```python
from sqlalchemy import delete, func, or_, select, update
```

Add to `FoodMemoryRepository` class (e.g., below `delete_by_name`):

```python
    # Summary: Appends `alias` to the row's aliases array if not already present.
    # Parameters:
    # - user_key (str): Owner.
    # - normalized_name (str): Canonical row identifier.
    # - alias (str): Already-normalized alias to add.
    # - now (DateTimeValue): Timestamp for updated_at.
    # Returns:
    # - dict[str, Any] | None: Updated row, or None if no such food_memory row exists.
    async def add_alias(
        self,
        user_key: str,
        normalized_name: str,
        alias: str,
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        stmt = (
            update(food_memory)
            .where(food_memory.c.user_key == user_key)
            .where(food_memory.c.normalized_name == normalized_name)
            .values(
                aliases=func.array(
                    select(func.unnest(func.array_append(food_memory.c.aliases, alias)))
                    .distinct()
                    .scalar_subquery()
                ),
                updated_at=now,
            )
            .returning(*_row_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    # Summary: Removes `alias` from the row's aliases array. No-op if absent.
    async def remove_alias(
        self,
        user_key: str,
        normalized_name: str,
        alias: str,
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        stmt = (
            update(food_memory)
            .where(food_memory.c.user_key == user_key)
            .where(food_memory.c.normalized_name == normalized_name)
            .values(
                aliases=func.array_remove(food_memory.c.aliases, alias),
                updated_at=now,
            )
            .returning(*_row_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None
```

Note: the `array_append` + `unnest` + `distinct` + `array` rebuild is the idiomatic Postgres pattern for "append if absent." If preferred, replace with a CASE expression — both produce the same result.

- [ ] **Step 4: Run tests to verify they pass**

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_aliases.py -v -k "food_memory_add_alias or food_memory_remove_alias"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/diet_tracker_server/repositories/food_memory.py tests/integration/test_aliases.py
git commit -m "feat(repo): add add_alias/remove_alias to FoodMemoryRepository"
```

---

## Task 7: `meals` repo — `add_alias` / `remove_alias`

**Files:**
- Modify: `src/diet_tracker_server/repositories/meals.py`
- Test: `tests/integration/test_aliases.py`

- [ ] **Step 1: Write the failing integration tests**

Append to `tests/integration/test_aliases.py`:

```python
@pytest.mark.asyncio
async def test_meals_add_alias_appends(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    result = await session.execute(
        text(
            "insert into meals (user_key, name, normalized_name, created_at, updated_at) "
            "values (:uk, 'Wrap', 'wrap', :now, :now) returning id"
        ),
        {"uk": user_key, "now": now},
    )
    meal_id = result.scalar_one()
    await session.commit()

    repo = MealsRepository(session)
    updated = await repo.add_alias(
        meal_id=meal_id, user_key=user_key, alias="the wrap", now=now,
    )
    await session.commit()
    assert updated is not None
    assert list(updated["aliases"]) == ["the wrap"]


@pytest.mark.asyncio
async def test_meals_remove_alias(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    result = await session.execute(
        text(
            "insert into meals (user_key, name, normalized_name, aliases, created_at, updated_at) "
            "values (:uk, 'Wrap', 'wrap', ARRAY['the wrap', 'lunch']::text[], :now, :now) returning id"
        ),
        {"uk": user_key, "now": now},
    )
    meal_id = result.scalar_one()
    await session.commit()

    repo = MealsRepository(session)
    updated = await repo.remove_alias(
        meal_id=meal_id, user_key=user_key, alias="the wrap", now=now,
    )
    await session.commit()
    assert list(updated["aliases"]) == ["lunch"]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_aliases.py -v -k "meals_add_alias or meals_remove_alias"`
Expected: FAIL.

- [ ] **Step 3: Implement `add_alias` and `remove_alias`**

Add `func` to imports in `src/diet_tracker_server/repositories/meals.py` (already imported). Add the methods to `MealsRepository`:

```python
    # Summary: Appends `alias` to the meal's aliases array if not already present.
    async def add_alias(
        self,
        meal_id: UUID,
        user_key: str,
        alias: str,
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        stmt = (
            update(meals)
            .where(meals.c.id == meal_id)
            .where(meals.c.user_key == user_key)
            .values(
                aliases=func.array(
                    select(func.unnest(func.array_append(meals.c.aliases, alias)))
                    .distinct()
                    .scalar_subquery()
                ),
                updated_at=now,
            )
            .returning(*_meal_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None

    # Summary: Removes `alias` from the meal's aliases array. No-op if absent.
    async def remove_alias(
        self,
        meal_id: UUID,
        user_key: str,
        alias: str,
        now: DateTimeValue,
    ) -> dict[str, Any] | None:
        stmt = (
            update(meals)
            .where(meals.c.id == meal_id)
            .where(meals.c.user_key == user_key)
            .values(
                aliases=func.array_remove(meals.c.aliases, alias),
                updated_at=now,
            )
            .returning(*_meal_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().first()
        return dict(row) if row else None
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_aliases.py -v -k "meals_add_alias or meals_remove_alias"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/diet_tracker_server/repositories/meals.py tests/integration/test_aliases.py
git commit -m "feat(repo): add add_alias/remove_alias to MealsRepository"
```

---

## Task 8: Service helpers — collision pre-check + de-dup

**Files:**
- Modify: `src/diet_tracker_server/services/food_memory_service.py`
- Modify: `src/diet_tracker_server/services/meals_service.py`
- Test: `tests/integration/test_aliases.py`

- [ ] **Step 1: Write the failing integration test**

Append to `tests/integration/test_aliases.py`:

```python
@pytest.mark.asyncio
async def test_food_memory_alias_collision_pre_check(session: AsyncSession) -> None:
    from diet_tracker_server.services.food_memory_service import assert_food_alias_available

    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, created_at, updated_at) "
            "values (:uk, 'Almond Butter', 'almond butter', 2, 'AB', 'per_100g', 100, 1, 1, 1, :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    with pytest.raises(ValueError) as excinfo:
        await assert_food_alias_available(
            session=session,
            user_key=user_key,
            alias="almond butter",
            exclude_normalized_name=None,
        )
    assert "almond butter" in str(excinfo.value)


@pytest.mark.asyncio
async def test_food_memory_alias_collision_excludes_own_row(session: AsyncSession) -> None:
    from diet_tracker_server.services.food_memory_service import assert_food_alias_available

    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, aliases, created_at, updated_at) "
            "values (:uk, 'PB', 'peanut butter', 1, 'PB', 'per_100g', 100, 1, 1, 1, ARRAY['pb']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    await assert_food_alias_available(
        session=session,
        user_key=user_key,
        alias="pb",
        exclude_normalized_name="peanut butter",
    )
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_aliases.py -v -k alias_collision`
Expected: FAIL with ImportError.

- [ ] **Step 3: Add helpers**

Add to `src/diet_tracker_server/services/food_memory_service.py`:

```python
from sqlalchemy import or_, select

from diet_tracker_server.repositories.tables import food_memory
from diet_tracker_server.services.normalize import normalize_name


def normalize_alias_list(aliases: list[str], canonical_normalized_name: str) -> list[str]:
    """Normalize aliases, drop empties, drop dups, drop alias equal to canonical name."""
    seen: set[str] = set()
    out: list[str] = []
    for raw in aliases:
        norm = normalize_name(raw)
        if not norm or norm == canonical_normalized_name or norm in seen:
            continue
        seen.add(norm)
        out.append(norm)
    return out


async def assert_food_alias_available(
    session: AsyncSession,
    user_key: str,
    alias: str,
    exclude_normalized_name: str | None,
) -> None:
    """Raise ValueError if `alias` is already used as a canonical name or alias on another row."""
    stmt = (
        select(food_memory.c.normalized_name)
        .where(food_memory.c.user_key == user_key)
        .where(
            or_(
                food_memory.c.normalized_name == alias,
                food_memory.c.aliases.any(alias),
            )
        )
    )
    if exclude_normalized_name is not None:
        stmt = stmt.where(food_memory.c.normalized_name != exclude_normalized_name)
    result = await session.execute(stmt)
    existing = result.scalar_one_or_none()
    if existing is not None:
        raise ValueError(
            f"alias '{alias}' is already used by food memory entry '{existing}'"
        )
```

Add a near-identical helper to `src/diet_tracker_server/services/meals_service.py` (keyed by `meal_id` rather than name for the exclusion):

```python
from sqlalchemy import or_, select
from uuid import UUID

from diet_tracker_server.repositories.tables import meals as meals_table
from diet_tracker_server.services.normalize import normalize_name


def normalize_alias_list(aliases: list[str], canonical_normalized_name: str) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for raw in aliases:
        norm = normalize_name(raw)
        if not norm or norm == canonical_normalized_name or norm in seen:
            continue
        seen.add(norm)
        out.append(norm)
    return out


async def assert_meal_alias_available(
    session: AsyncSession,
    user_key: str,
    alias: str,
    exclude_meal_id: UUID | None,
) -> None:
    stmt = (
        select(meals_table.c.normalized_name)
        .where(meals_table.c.user_key == user_key)
        .where(
            or_(
                meals_table.c.normalized_name == alias,
                meals_table.c.aliases.any(alias),
            )
        )
    )
    if exclude_meal_id is not None:
        stmt = stmt.where(meals_table.c.id != exclude_meal_id)
    result = await session.execute(stmt)
    existing = result.scalar_one_or_none()
    if existing is not None:
        raise ValueError(
            f"alias '{alias}' is already used by meal '{existing}'"
        )
```

Note: keep the existing top-level imports and the existing `resolve_food_by_name` / meal service functions intact; only add the new symbols.

- [ ] **Step 4: Run tests to verify they pass**

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_aliases.py -v -k alias_collision`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/diet_tracker_server/services/food_memory_service.py src/diet_tracker_server/services/meals_service.py tests/integration/test_aliases.py
git commit -m "feat(services): add alias collision pre-check + normalize_alias_list helpers"
```

---

## Task 9: MCP — `add_food_alias` / `remove_food_alias`

**Files:**
- Modify: `src/diet_tracker_server/mcp/server.py`
- Modify: `tests/test_mcp_tools.py`

- [ ] **Step 1: Update the expected-tools test to require the new names**

In `tests/test_mcp_tools.py`, add to the `expected` set inside `test_build_mcp_registers_expected_tools`:

```python
        "add_food_alias",
        "remove_food_alias",
        "add_meal_alias",
        "remove_meal_alias",
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `uv run pytest tests/test_mcp_tools.py::test_build_mcp_registers_expected_tools -v`
Expected: FAIL — assertion fails because the new tools aren't registered.

- [ ] **Step 3: Update `_food_memory_entry` to include `aliases`**

In `src/diet_tracker_server/mcp/server.py`, update `_food_memory_entry`:

```python
def _food_memory_entry(row: dict[str, Any]) -> FoodMemoryEntry:
    return FoodMemoryEntry(
        id=row["id"],
        user_key=row["user_key"],
        name=row["name"],
        normalized_name=row["normalized_name"],
        usda_fdc_id=None if row["usda_fdc_id"] is None else int(row["usda_fdc_id"]),
        usda_description=row["usda_description"],
        custom_food_id=row["custom_food_id"],
        basis=row["basis"],
        serving_size=None if row["serving_size"] is None else float(row["serving_size"]),
        serving_size_unit=row["serving_size_unit"],
        calories=None if row["calories"] is None else int(row["calories"]),
        protein_g=None if row["protein_g"] is None else float(row["protein_g"]),
        carbs_g=None if row["carbs_g"] is None else float(row["carbs_g"]),
        fat_g=None if row["fat_g"] is None else float(row["fat_g"]),
        aliases=list(row.get("aliases") or []),
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )
```

- [ ] **Step 4: Add the two new MCP tools**

In `src/diet_tracker_server/mcp/server.py`, in the `# ---------------- food memory ----------------` section (alongside `remember_food` / `forget_food`), import the new service helper at the top of the file:

```python
from diet_tracker_server.services.food_memory_service import (
    assert_food_alias_available,
    normalize_alias_list,
    resolve_food_by_name,
)
```

Add tools inside `build_mcp`:

```python
    @mcp.tool
    async def add_food_alias(name: str, alias: str) -> FoodMemoryEntry:
        """Add an alternate phrasing for an existing food memory entry. Looks up the entry
        by canonical `name` (normalized) and appends a normalized `alias` to its aliases.
        Fails when the alias is already used as a canonical name or alias by another entry.
        """
        normalized_name = normalize_name(name)
        normalized_alias = normalize_name(alias)
        if not normalized_alias:
            raise ToolError("Alias must be non-empty after normalization")
        if normalized_alias == normalized_name:
            # No-op: aliasing a row to its own name.
            async with get_session() as session:
                repo = FoodMemoryRepository(session)
                row = await repo.get_by_name(user_key=user_key, normalized_name=normalized_name)
            if row is None:
                raise ToolError("Food memory not found")
            return _food_memory_entry(row)
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            async with transaction(session):
                try:
                    await assert_food_alias_available(
                        session=session,
                        user_key=user_key,
                        alias=normalized_alias,
                        exclude_normalized_name=normalized_name,
                    )
                except ValueError as exc:
                    raise ToolError(str(exc)) from exc
                repo = FoodMemoryRepository(session)
                row = await repo.add_alias(
                    user_key=user_key,
                    normalized_name=normalized_name,
                    alias=normalized_alias,
                    now=now,
                )
            if row is None:
                raise ToolError("Food memory not found")
        return _food_memory_entry(row)

    @mcp.tool
    async def remove_food_alias(name: str, alias: str) -> FoodMemoryEntry:
        """Remove an alternate phrasing from an existing food memory entry. No-op if absent."""
        normalized_name = normalize_name(name)
        normalized_alias = normalize_name(alias)
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = FoodMemoryRepository(session)
            async with transaction(session):
                row = await repo.remove_alias(
                    user_key=user_key,
                    normalized_name=normalized_name,
                    alias=normalized_alias,
                    now=now,
                )
            if row is None:
                raise ToolError("Food memory not found")
        return _food_memory_entry(row)
```

- [ ] **Step 5: Run the expected-tools test to verify food alias tools register**

Run: `uv run pytest tests/test_mcp_tools.py::test_build_mcp_registers_expected_tools -v`
Expected: still FAIL (meal alias tools not yet added — that's Task 10).

For now, run a narrower assertion:

```python
import asyncio
from unittest.mock import MagicMock
from diet_tracker_server.mcp import build_mcp

async def _check():
    mcp = build_mcp(lambda: MagicMock())
    names = {t.name for t in await mcp.list_tools()}
    return "add_food_alias" in names and "remove_food_alias" in names

assert asyncio.run(_check())
```
Expected: True.

- [ ] **Step 6: Commit**

```bash
git add src/diet_tracker_server/mcp/server.py tests/test_mcp_tools.py
git commit -m "feat(mcp): add add_food_alias / remove_food_alias tools"
```

---

## Task 10: MCP — `add_meal_alias` / `remove_meal_alias`

**Files:**
- Modify: `src/diet_tracker_server/mcp/server.py`

- [ ] **Step 1: Run the expected-tools test as a failing baseline**

Run: `uv run pytest tests/test_mcp_tools.py::test_build_mcp_registers_expected_tools -v`
Expected: FAIL because `add_meal_alias` / `remove_meal_alias` are missing.

- [ ] **Step 2: Update `_meal_response` and `MealSummary` build sites to include `aliases`**

In `src/diet_tracker_server/mcp/server.py`:

Update `_meal_response`:

```python
def _meal_response(meal_row: dict[str, Any], item_rows: list[dict[str, Any]]) -> MealResponse:
    return MealResponse(
        id=meal_row["id"],
        user_key=meal_row["user_key"],
        name=meal_row["name"],
        normalized_name=meal_row["normalized_name"],
        notes=meal_row["notes"],
        aliases=list(meal_row.get("aliases") or []),
        created_at=meal_row["created_at"],
        updated_at=meal_row["updated_at"],
        items=[_meal_item_response(r) for r in item_rows],
    )
```

In `list_meals` tool (around line 645), add `aliases` to the `MealSummary` construction:

```python
        return [
            MealSummary(
                id=row["id"],
                name=row["name"],
                normalized_name=row["normalized_name"],
                notes=row["notes"],
                aliases=list(row.get("aliases") or []),
                item_count=int(row["item_count"]),
                total_calories=int(row["total_calories"]),
                total_protein_g=float(row["total_protein_g"]),
                total_carbs_g=float(row["total_carbs_g"]),
                total_fat_g=float(row["total_fat_g"]),
            )
            for row in rows
        ]
```

- [ ] **Step 3: Add the two new meal alias tools**

Import the helper at the top:

```python
from diet_tracker_server.services.meals_service import (
    assert_meal_alias_available,
    create_meal_with_items,
    log_meal as log_meal_service,
    normalize_alias_list as normalize_meal_alias_list,
)
```

(Rename collision: the food-memory service also exports `normalize_alias_list`; use `as` to disambiguate.)

Add tools inside `build_mcp`, in the meals section:

```python
    @mcp.tool
    async def add_meal_alias(meal_id: str, alias: str) -> MealResponse:
        """Add an alternate phrasing for an existing meal. Looks up by `meal_id` and
        appends a normalized `alias`. Fails when the alias is already used as a canonical
        name or alias by another meal.
        """
        try:
            meal_uuid = UUID(meal_id)
        except ValueError as exc:
            raise ToolError(f"Invalid meal_id '{meal_id}'") from exc
        normalized_alias = normalize_name(alias)
        if not normalized_alias:
            raise ToolError("Alias must be non-empty after normalization")
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = MealsRepository(session)
            meal_row = await repo.get_meal(meal_uuid, user_key)
            if meal_row is None:
                raise ToolError("Meal not found")
            if normalized_alias == meal_row["normalized_name"]:
                item_rows = await repo.list_items(meal_uuid)
                return _meal_response(meal_row, item_rows)
            async with transaction(session):
                try:
                    await assert_meal_alias_available(
                        session=session,
                        user_key=user_key,
                        alias=normalized_alias,
                        exclude_meal_id=meal_uuid,
                    )
                except ValueError as exc:
                    raise ToolError(str(exc)) from exc
                updated = await repo.add_alias(
                    meal_id=meal_uuid,
                    user_key=user_key,
                    alias=normalized_alias,
                    now=now,
                )
            if updated is None:
                raise ToolError("Meal not found")
            item_rows = await repo.list_items(meal_uuid)
        return _meal_response(updated, item_rows)

    @mcp.tool
    async def remove_meal_alias(meal_id: str, alias: str) -> MealResponse:
        """Remove an alternate phrasing from an existing meal. No-op if absent."""
        try:
            meal_uuid = UUID(meal_id)
        except ValueError as exc:
            raise ToolError(f"Invalid meal_id '{meal_id}'") from exc
        normalized_alias = normalize_name(alias)
        now = DateTimeValue.now(tz=tz)
        async with get_session() as session:
            repo = MealsRepository(session)
            async with transaction(session):
                updated = await repo.remove_alias(
                    meal_id=meal_uuid,
                    user_key=user_key,
                    alias=normalized_alias,
                    now=now,
                )
            if updated is None:
                raise ToolError("Meal not found")
            item_rows = await repo.list_items(meal_uuid)
        return _meal_response(updated, item_rows)
```

- [ ] **Step 4: Run the expected-tools test to verify all four register**

Run: `uv run pytest tests/test_mcp_tools.py::test_build_mcp_registers_expected_tools -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/diet_tracker_server/mcp/server.py
git commit -m "feat(mcp): add add_meal_alias / remove_meal_alias tools; surface aliases in responses"
```

---

## Task 11: MCP — extend `remember_food` and `create_meal` with `aliases` param

**Files:**
- Modify: `src/diet_tracker_server/mcp/server.py`
- Modify: `src/diet_tracker_server/services/meals_service.py` (the existing `create_meal_with_items` function)
- Modify: `src/diet_tracker_server/repositories/food_memory.py` (the existing `upsert_usda` to accept aliases)

- [ ] **Step 1: Write the failing integration test**

Append to `tests/integration/test_aliases.py`:

```python
@pytest.mark.asyncio
async def test_remember_food_persists_aliases(session: AsyncSession) -> None:
    from datetime import datetime as DateTimeValue
    from datetime import timezone as TimezoneValue

    from diet_tracker_server.repositories.food_memory import FoodMemoryRepository

    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    repo = FoodMemoryRepository(session)
    await repo.upsert_usda(
        user_key=user_key,
        name="Peanut Butter",
        normalized_name="peanut butter",
        usda_fdc_id=1,
        usda_description="PB",
        basis="per_100g",
        serving_size=None,
        serving_size_unit=None,
        calories=100,
        protein_g=1.0,
        carbs_g=1.0,
        fat_g=1.0,
        now=now,
        aliases=["pb", "pbs"],
    )
    await session.commit()

    row = await repo.get_by_name(user_key=user_key, normalized_name="pb")
    assert row is not None
    assert sorted(row["aliases"]) == ["pb", "pbs"]


@pytest.mark.asyncio
async def test_remember_food_upsert_preserves_existing_aliases_when_not_provided(session: AsyncSession) -> None:
    from datetime import datetime as DateTimeValue
    from datetime import timezone as TimezoneValue

    from diet_tracker_server.repositories.food_memory import FoodMemoryRepository

    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    repo = FoodMemoryRepository(session)
    await repo.upsert_usda(
        user_key=user_key, name="PB", normalized_name="peanut butter",
        usda_fdc_id=1, usda_description="PB", basis="per_100g",
        serving_size=None, serving_size_unit=None,
        calories=100, protein_g=1.0, carbs_g=1.0, fat_g=1.0,
        now=now, aliases=["pb"],
    )
    await session.commit()
    # Second upsert without aliases — should NOT clobber existing aliases.
    await repo.upsert_usda(
        user_key=user_key, name="PB", normalized_name="peanut butter",
        usda_fdc_id=1, usda_description="PB", basis="per_100g",
        serving_size=None, serving_size_unit=None,
        calories=200, protein_g=2.0, carbs_g=2.0, fat_g=2.0,
        now=now, aliases=None,
    )
    await session.commit()
    row = await repo.get_by_name(user_key=user_key, normalized_name="peanut butter")
    assert list(row["aliases"]) == ["pb"]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_aliases.py -v -k "remember_food_persists or upsert_preserves"`
Expected: FAIL — `upsert_usda` doesn't accept `aliases`.

- [ ] **Step 3: Extend `FoodMemoryRepository.upsert_usda` to take an `aliases` parameter**

In `src/diet_tracker_server/repositories/food_memory.py`, update the signature and body:

```python
    async def upsert_usda(
        self,
        user_key: str,
        name: str,
        normalized_name: str,
        usda_fdc_id: int,
        usda_description: str,
        basis: str,
        serving_size: float | None,
        serving_size_unit: str | None,
        calories: int,
        protein_g: float,
        carbs_g: float,
        fat_g: float,
        now: DateTimeValue,
        aliases: list[str] | None = None,
    ) -> dict[str, Any]:
        values: dict[str, Any] = dict(
            user_key=user_key,
            name=name,
            normalized_name=normalized_name,
            usda_fdc_id=usda_fdc_id,
            usda_description=usda_description,
            custom_food_id=None,
            basis=basis,
            serving_size=serving_size,
            serving_size_unit=serving_size_unit,
            calories=calories,
            protein_g=protein_g,
            carbs_g=carbs_g,
            fat_g=fat_g,
            created_at=now,
            updated_at=now,
        )
        if aliases is not None:
            values["aliases"] = aliases
        insert_stmt = pg_insert(food_memory).values(**values)
        set_: dict[str, Any] = {
            "name": insert_stmt.excluded.name,
            "usda_fdc_id": insert_stmt.excluded.usda_fdc_id,
            "usda_description": insert_stmt.excluded.usda_description,
            "custom_food_id": None,
            "basis": insert_stmt.excluded.basis,
            "serving_size": insert_stmt.excluded.serving_size,
            "serving_size_unit": insert_stmt.excluded.serving_size_unit,
            "calories": insert_stmt.excluded.calories,
            "protein_g": insert_stmt.excluded.protein_g,
            "carbs_g": insert_stmt.excluded.carbs_g,
            "fat_g": insert_stmt.excluded.fat_g,
            "updated_at": now,
        }
        if aliases is not None:
            set_["aliases"] = insert_stmt.excluded.aliases
        stmt = insert_stmt.on_conflict_do_update(
            index_elements=[food_memory.c.user_key, food_memory.c.normalized_name],
            set_=set_,
        ).returning(*_row_columns())
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())
```

The branch matters: when the MCP caller doesn't pass `aliases`, the on-conflict update leaves the existing array untouched.

- [ ] **Step 4: Plumb `aliases` through the `remember_food` MCP tool**

In `src/diet_tracker_server/mcp/server.py`, update the `remember_food` signature and body:

```python
    @mcp.tool
    async def remember_food(
        name: str,
        fdc_id: int,
        usda_description: str,
        basis: Literal["per_100g", "per_serving", "per_unit"],
        calories: int = Field(ge=0),
        protein_g: float = Field(ge=0),
        carbs_g: float = Field(ge=0),
        fat_g: float = Field(ge=0),
        serving_size: float | None = None,
        serving_size_unit: str | None = None,
        aliases: list[str] | None = None,
    ) -> FoodMemoryEntry:
        """Save a USDA pointer keyed by `name`. Optionally provide `aliases` (additional
        phrasings that should resolve to the same entry). Macros must be at the indicated
        `basis` (NOT scaled to a previous quantity).
        """
        now = DateTimeValue.now(tz=tz)
        normalized = normalize_name(name)
        cleaned_aliases: list[str] | None = None
        if aliases is not None:
            cleaned_aliases = normalize_alias_list(aliases, canonical_normalized_name=normalized)
        async with get_session() as session:
            async with transaction(session):
                if cleaned_aliases:
                    for a in cleaned_aliases:
                        try:
                            await assert_food_alias_available(
                                session=session,
                                user_key=user_key,
                                alias=a,
                                exclude_normalized_name=normalized,
                            )
                        except ValueError as exc:
                            raise ToolError(str(exc)) from exc
                repo = FoodMemoryRepository(session)
                row = await repo.upsert_usda(
                    user_key=user_key,
                    name=name,
                    normalized_name=normalized,
                    usda_fdc_id=fdc_id,
                    usda_description=usda_description,
                    basis=basis,
                    serving_size=serving_size,
                    serving_size_unit=serving_size_unit,
                    calories=calories,
                    protein_g=protein_g,
                    carbs_g=carbs_g,
                    fat_g=fat_g,
                    now=now,
                    aliases=cleaned_aliases,
                )
        return _food_memory_entry(row)
```

Imports: add `normalize_alias_list` to the food_memory_service import (already present in Task 9 if `as` rename was used — keep both names available).

- [ ] **Step 5: Plumb `aliases` through `create_meal`**

In `src/diet_tracker_server/services/meals_service.py`, modify `create_meal_with_items` to accept and pass aliases. Find the function and update its signature to read `payload: MealCreate` (which already has `aliases`); then where it inserts into `meals`, include `aliases=normalize_meal_alias_list(payload.aliases, normalize_name(payload.name))` (renaming the helper or referencing the meals-service `normalize_alias_list` directly).

In `src/diet_tracker_server/repositories/meals.py`, extend `create_meal` to accept `aliases: list[str] = ()`:

```python
    async def create_meal(
        self,
        user_key: str,
        name: str,
        normalized_name: str,
        notes: str | None,
        now: DateTimeValue,
        aliases: list[str] | None = None,
    ) -> dict[str, Any]:
        values: dict[str, Any] = dict(
            user_key=user_key,
            name=name,
            normalized_name=normalized_name,
            notes=notes,
            created_at=now,
            updated_at=now,
        )
        if aliases is not None:
            values["aliases"] = aliases
        stmt = (
            pg_insert(meals)
            .values(**values)
            .returning(*_meal_columns())
        )
        result = await self._session.execute(stmt)
        return dict(result.mappings().one())
```

Then in `services/meals_service.py::create_meal_with_items`, before inserting, call `assert_meal_alias_available` for each alias (with `exclude_meal_id=None`), de-dup via `normalize_alias_list`, then pass to `repo.create_meal(..., aliases=cleaned)`.

The MCP `create_meal` tool already passes `payload = MealCreate(name=name, notes=notes, items=items)` — change it to:

```python
        payload = MealCreate(name=name, notes=notes, items=items, aliases=aliases or [])
```

and add the `aliases: list[str] | None = None` parameter to the tool signature with a docstring update.

- [ ] **Step 6: Run all integration tests to verify**

Run: `TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration -v`
Expected: all PASS, including the new `test_remember_food_persists_aliases` and `test_remember_food_upsert_preserves_existing_aliases_when_not_provided`.

- [ ] **Step 7: Commit**

```bash
git add src/diet_tracker_server/repositories/food_memory.py src/diet_tracker_server/repositories/meals.py src/diet_tracker_server/services/meals_service.py src/diet_tracker_server/mcp/server.py tests/integration/test_aliases.py
git commit -m "feat(mcp): accept aliases on remember_food and create_meal"
```

---

## Task 12: MCP — workflow instructions update

**Files:**
- Modify: `src/diet_tracker_server/mcp/server.py`

- [ ] **Step 1: Update the workflow-instructions test**

In `tests/test_mcp_tools.py`, add:

```python
@pytest.mark.asyncio
async def test_workflow_instructions_mention_aliases() -> None:
    from diet_tracker_server.mcp.server import WORKFLOW_INSTRUCTIONS
    assert "add_meal_alias" in WORKFLOW_INSTRUCTIONS
    assert "add_food_alias" in WORKFLOW_INSTRUCTIONS
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `uv run pytest tests/test_mcp_tools.py::test_workflow_instructions_mention_aliases -v`
Expected: FAIL.

- [ ] **Step 3: Append to `WORKFLOW_INSTRUCTIONS`**

In `src/diet_tracker_server/mcp/server.py`, modify `WORKFLOW_INSTRUCTIONS` to add a new bullet after step 4:

```python
WORKFLOW_INSTRUCTIONS = """
Diet tracking workflow. Follow this order on every food-related interaction:

1) MEALS FIRST. Call `list_meals` once early in the conversation. If anything the user
   says matches a saved meal name (be liberal — "my breakfast", "the wrap", etc.), call
   `log_meal` with that meal_id and stop. Meals log all their ingredients at the original
   quantities; do not scale.

2) MEMORY NEXT. For each individual food the user mentions, call `resolve_food(name)`
   FIRST. If it returns `type != "none"`, use the returned macros and basis to scale to
   the user's quantity, then call `log_food` (passing `fdc_id` for memory_usda hits or
   `custom_food_id` for custom_food hits). Skip `search_food`.

3) USDA SEARCH FALLBACK. Only when memory misses, call `search_food` and pick a candidate.

4) AUTO-REMEMBER ON CORRECTIONS. If the user corrects your USDA pick (different food, or
   you got the macros wrong), after logging the corrected version call `remember_food`
   with the corrected fdc_id, basis, and per-basis macros so this user's next mention of
   the same name resolves directly. For corrections backed by a photo or user-provided
   macros (no USDA equivalent), call `save_custom_food` which auto-remembers.

5) AUTO-ALIAS ON NAME DRIFT. When the user refers to an existing memory entry or saved
   meal under a phrasing that didn't exact-match (you matched it from `list_meals` /
   `list_remembered_foods` context, not from `resolve_food` / `get_meal` returning it
   directly), call `add_meal_alias` or `add_food_alias` with the user's phrasing after
   logging. Skip if the phrasing is generic ("breakfast", "lunch", "the usual") or if
   the user explicitly disambiguated this turn. Skip if you're not confident the
   phrasing should always map to the same entity.

6) PHOTO / MANUAL MACROS. When the user provides macros directly (via photo or text)
   without a USDA reference, call `save_custom_food` with `basis="per_serving"` (default
   for photo-derived foods) — this creates the custom food and writes memory in one step.
   Then call `log_food` with the returned `custom_food_id`.

`forget_food(name)` and `list_remembered_foods()` let the user audit memory.
""".strip()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `uv run pytest tests/test_mcp_tools.py -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/diet_tracker_server/mcp/server.py tests/test_mcp_tools.py
git commit -m "feat(mcp): add AUTO-ALIAS workflow step to instructions"
```

---

## Task 13: iOS DTOs — `aliases` on `MealSummary` and `Meal`

**Files:**
- Modify: `diet-tracker-ios/DietTracker/Models/Meal.swift`

Note: change directory to the iOS repo (`cd ../diet-tracker-ios` from the server repo).

- [ ] **Step 1: Write the failing test fixture + test**

Create `diet-tracker-ios/DietTrackerTests/Fixtures/meal_summary_with_aliases.json`:

```json
{
  "meals": [
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "Wrap",
      "normalized_name": "wrap",
      "notes": null,
      "aliases": ["the wrap", "lunch wrap"],
      "item_count": 2,
      "total_calories": 500,
      "total_protein_g": 30.0,
      "total_carbs_g": 50.0,
      "total_fat_g": 15.0
    }
  ]
}
```

Add to `diet-tracker-ios/DietTrackerTests/MealsClientTests.swift` (or a suitable existing test file — check `find DietTrackerTests -name '*.swift'`):

```swift
func testMealSummaryDecodesAliases() throws {
    let data = try fixtureData(named: "meal_summary_with_aliases")
    let decoded = try JSONDecoder.dietTrackerDefault().decode(MealsListResponse.self, from: data)
    XCTAssertEqual(decoded.meals.first?.aliases, ["the wrap", "lunch wrap"])
}

func testMealSummaryDecodesWithoutAliasesField() throws {
    let json = """
    {"meals": [{"id":"11111111-1111-1111-1111-111111111111","name":"Wrap","normalized_name":"wrap","notes":null,"item_count":0,"total_calories":0,"total_protein_g":0,"total_carbs_g":0,"total_fat_g":0}]}
    """.data(using: .utf8)!
    let decoded = try JSONDecoder.dietTrackerDefault().decode(MealsListResponse.self, from: json)
    XCTAssertEqual(decoded.meals.first?.aliases, [])
}
```

(If `fixtureData(named:)` doesn't exist as a helper, inline the JSON or follow the existing fixture-loading pattern in that test file.)

- [ ] **Step 2: Run the test to verify it fails**

Run:
```
cd ../diet-tracker-ios
xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/MealsClientTests/testMealSummaryDecodesAliases
```
Expected: FAIL (no `aliases` property on `MealSummary`).

- [ ] **Step 3: Add `aliases` to `MealSummary` and `Meal`**

In `diet-tracker-ios/DietTracker/Models/Meal.swift`, update `MealSummary`:

```swift
struct MealSummary: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let normalizedName: String
    let notes: String?
    let aliases: [String]
    let itemCount: Int
    let totalCalories: Int
    let totalProteinG: Double
    let totalCarbsG: Double
    let totalFatG: Double

    enum CodingKeys: String, CodingKey {
        case id, name, notes, aliases
        case normalizedName = "normalized_name"
        case itemCount = "item_count"
        case totalCalories = "total_calories"
        case totalProteinG = "total_protein_g"
        case totalCarbsG = "total_carbs_g"
        case totalFatG = "total_fat_g"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        normalizedName = try c.decode(String.self, forKey: .normalizedName)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        itemCount = try c.decode(Int.self, forKey: .itemCount)
        totalCalories = try c.decode(Int.self, forKey: .totalCalories)
        totalProteinG = try c.decode(Double.self, forKey: .totalProteinG)
        totalCarbsG = try c.decode(Double.self, forKey: .totalCarbsG)
        totalFatG = try c.decode(Double.self, forKey: .totalFatG)
    }

    var totals: MacroTotals {
        MacroTotals(
            calories: totalCalories,
            proteinG: totalProteinG,
            carbsG: totalCarbsG,
            fatG: totalFatG
        )
    }
}
```

(The custom `init(from:)` is required so a missing `aliases` field defaults to `[]` instead of failing.)

Update `Meal`:

```swift
struct Meal: Codable, Identifiable, Hashable {
    let id: UUID
    let userKey: String
    let name: String
    let normalizedName: String
    let notes: String?
    let aliases: [String]
    let createdAt: Date
    let updatedAt: Date
    let items: [MealItem]

    enum CodingKeys: String, CodingKey {
        case id, name, notes, items, aliases
        case userKey = "user_key"
        case normalizedName = "normalized_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        userKey = try c.decode(String.self, forKey: .userKey)
        name = try c.decode(String.self, forKey: .name)
        normalizedName = try c.decode(String.self, forKey: .normalizedName)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        items = try c.decode([MealItem].self, forKey: .items)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```
xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/MealsClientTests
```
Expected: PASS.

- [ ] **Step 5: Commit (iOS repo)**

```bash
git add DietTracker/Models/Meal.swift DietTrackerTests/Fixtures/meal_summary_with_aliases.json DietTrackerTests/MealsClientTests.swift
git commit -m "feat(models): decode aliases on MealSummary and Meal (defaults to [])"
```

---

## Done

After all tasks pass, run the full server test suite and the iOS test suite once more:

```
# server repo
uv run pytest tests/ -v
TEST_DATABASE_URL=postgresql://localhost/test uv run pytest -m integration -v

# iOS repo
xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

The feature is shippable when:
1. All unit + integration tests pass on both repos.
2. Alembic migration applies and downgrades cleanly against a scratch Postgres.
3. The MCP `list_tools()` response includes the four new alias tools.
4. The iOS app builds and decodes both old (no `aliases`) and new (with `aliases`) backend responses.
