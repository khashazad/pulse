# Meal Link on Food Entries — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stamp every `food_entries` row created by `log_meal` with the originating meal's id (`meal_id`, FK to `meals.id`, `ON DELETE SET NULL`) and a denormalized `meal_name` snapshot, and expose both fields on every entry response payload.

**Architecture:** Add two nullable columns to `food_entries`. Thread the values through `FoodEntryCreate` → `EntriesRepository.create_food_entry` → `_food_entry_response_columns` → `FoodEntryResponse`. `services/meals_service.log_meal` is the only caller that populates them; manual entry creation leaves both NULL.

**Tech Stack:** FastAPI, SQLAlchemy Core (async psycopg3), Alembic, Pydantic v2, pytest (with `pytest.mark.integration` for DB tests).

**Spec:** `docs/superpowers/specs/2026-05-10-meal-link-on-entries-design.md`

**Companion plan (iOS):** `../diet-tracker-ios/docs/superpowers/plans/2026-05-10-collapsible-meal-rows.md` — depends on this one shipping first, but can be implemented in parallel because the iOS decoder treats both fields as optional.

---

## File Structure

**Modify:**
- `alembic/versions/20260510_000001_meal_link_on_entries.py` (new) — schema migration.
- `schema.sql` — idempotent additions mirroring the migration.
- `src/diet_tracker_server/repositories/tables.py` — add columns + index to `food_entries` `Table`.
- `src/diet_tracker_server/models/entries.py` — add fields to `FoodEntryCreate` and `FoodEntryResponse`.
- `src/diet_tracker_server/repositories/entries.py` — extend `_food_entry_response_columns` and `create_food_entry`.
- `src/diet_tracker_server/services/entries_service.py` — pass new fields from `FoodEntryCreate` into the repo call.
- `src/diet_tracker_server/services/meals_service.py::log_meal` — populate `meal_id` and `meal_name` on each `FoodEntryCreate`.
- `tests/integration/test_meals_and_memory.py` — extend `test_log_meal_expands_into_food_entries` and add deletion/rename cases.
- `tests/test_food_entry_model.py` — add a unit test that direct creation leaves both fields NULL.

No new modules; the change is additive across existing layers.

---

## Task 1: Migration (Alembic + schema.sql)

**Files:**
- Create: `alembic/versions/20260510_000001_meal_link_on_entries.py`
- Modify: `schema.sql`

- [ ] **Step 1: Write the Alembic migration**

Create `alembic/versions/20260510_000001_meal_link_on_entries.py`:

```python
"""Add meal_id and meal_name to food_entries.

Revision ID: 20260510_000001
Revises: 20260509_000001
Create Date: 2026-05-10T00:00:00Z
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "20260510_000001"
down_revision = "20260509_000001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "food_entries",
        sa.Column("meal_id", postgresql.UUID(as_uuid=True), nullable=True),
    )
    op.add_column(
        "food_entries",
        sa.Column("meal_name", sa.Text(), nullable=True),
    )
    op.create_foreign_key(
        "fk_food_entries_meal_id",
        "food_entries",
        "meals",
        ["meal_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_index(
        "idx_food_entries_meal_id",
        "food_entries",
        ["meal_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("idx_food_entries_meal_id", table_name="food_entries")
    op.drop_constraint("fk_food_entries_meal_id", "food_entries", type_="foreignkey")
    op.drop_column("food_entries", "meal_name")
    op.drop_column("food_entries", "meal_id")
```

- [ ] **Step 2: Mirror in `schema.sql` (idempotent)**

Append to `schema.sql` after the existing `food_entries` block (after the section that ends with the `food_entries_one_source` constraint check, around line 160):

```sql
alter table food_entries add column if not exists meal_id uuid;
alter table food_entries add column if not exists meal_name text;

do $body$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'fk_food_entries_meal_id'
  ) then
    alter table food_entries
      add constraint fk_food_entries_meal_id
      foreign key (meal_id) references meals(id) on delete set null;
  end if;
end
$body$;

create index if not exists idx_food_entries_meal_id on food_entries(meal_id);
```

- [ ] **Step 3: Run migration against a scratch DB and verify**

```bash
TEST_DATABASE_URL=postgresql+psycopg://localhost/diet_test uv run alembic upgrade head
```

Expected: head moves to `20260510_000001`. No errors.

Then verify columns exist:

```bash
psql diet_test -c "\d food_entries" | grep -E "meal_id|meal_name|fk_food_entries_meal_id|idx_food_entries_meal_id"
```

Expected: see all four lines (two columns, one FK, one index).

- [ ] **Step 4: Commit**

```bash
git add alembic/versions/20260510_000001_meal_link_on_entries.py schema.sql
git commit -m "feat: add meal_id/meal_name columns to food_entries"
```

---

## Task 2: SQLAlchemy table definition

**Files:**
- Modify: `src/diet_tracker_server/repositories/tables.py`

- [ ] **Step 1: Add the columns and index to the `food_entries` `Table`**

Locate the `food_entries = Table(...)` block (around line 153). Insert two `Column` lines just before the existing `Index("idx_food_entries_user_key", ...)`, and add a new `Index` after the existing `idx_food_entries_custom_food_id`:

```python
    Column(
        "meal_id",
        UUID(as_uuid=True),
        ForeignKey("meals.id", ondelete="SET NULL"),
        nullable=True,
    ),
    Column("meal_name", Text, nullable=True),
```

And after the existing custom_food_id index:

```python
    Index("idx_food_entries_meal_id", "meal_id"),
```

- [ ] **Step 2: Commit**

```bash
git add src/diet_tracker_server/repositories/tables.py
git commit -m "feat: add meal_id/meal_name to food_entries Table metadata"
```

---

## Task 3: Pydantic model fields

**Files:**
- Modify: `src/diet_tracker_server/models/entries.py`
- Test: `tests/test_food_entry_model.py`

- [ ] **Step 1: Write the failing test for the model fields**

Open `tests/test_food_entry_model.py` and add (preserve existing imports / tests):

```python
from uuid import UUID

from diet_tracker_server.models.entries import FoodEntryCreate, FoodEntryResponse


def test_food_entry_create_defaults_meal_link_to_none() -> None:
    entry = FoodEntryCreate(
        display_name="oats",
        quantity_text="80 g",
        usda_fdc_id=173904,
        usda_description="Oats, raw",
        calories=320,
        protein_g=10,
        carbs_g=54,
        fat_g=6,
    )
    assert entry.meal_id is None
    assert entry.meal_name is None


def test_food_entry_create_accepts_meal_link() -> None:
    meal_id = UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    entry = FoodEntryCreate(
        display_name="oats",
        quantity_text="80 g",
        usda_fdc_id=173904,
        usda_description="Oats, raw",
        calories=320,
        protein_g=10,
        carbs_g=54,
        fat_g=6,
        meal_id=meal_id,
        meal_name="Breakfast",
    )
    assert entry.meal_id == meal_id
    assert entry.meal_name == "Breakfast"


def test_food_entry_response_exposes_meal_link() -> None:
    fields = FoodEntryResponse.model_fields
    assert "meal_id" in fields
    assert "meal_name" in fields
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
uv run pytest tests/test_food_entry_model.py -v
```

Expected: the three new tests FAIL with attribute or validation errors referencing `meal_id` / `meal_name`.

- [ ] **Step 3: Add the fields to `FoodEntryCreate` and `FoodEntryResponse`**

In `src/diet_tracker_server/models/entries.py`, edit `FoodEntryCreate` (currently ends with `consumed_at: DateTimeValue | None = None`):

```python
class FoodEntryCreate(BaseModel):
    display_name: str
    quantity_text: str
    normalized_quantity_value: float | None = None
    normalized_quantity_unit: str | None = None
    usda_fdc_id: int | None = None
    usda_description: str | None = None
    custom_food_id: UUID | None = None
    calories: int = Field(ge=0)
    protein_g: float = Field(ge=0)
    carbs_g: float = Field(ge=0)
    fat_g: float = Field(ge=0)
    date: DateValue | None = None
    consumed_at: DateTimeValue | None = None
    meal_id: UUID | None = None
    meal_name: str | None = None

    @model_validator(mode="after")
    def _exactly_one_source(self) -> "FoodEntryCreate":
        has_usda = self.usda_fdc_id is not None
        has_custom = self.custom_food_id is not None
        if has_usda == has_custom:
            raise ValueError("Provide exactly one of usda_fdc_id or custom_food_id")
        if has_usda and not self.usda_description:
            raise ValueError("usda_description is required when usda_fdc_id is set")
        return self
```

Then edit `FoodEntryResponse` to add the two fields just before `consumed_at`:

```python
class FoodEntryResponse(BaseModel):
    id: UUID
    daily_log_id: UUID
    user_key: str
    entry_group_id: UUID
    display_name: str
    quantity_text: str
    normalized_quantity_value: float | None
    normalized_quantity_unit: str | None
    usda_fdc_id: int | None = None
    usda_description: str | None = None
    custom_food_id: UUID | None = None
    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float
    meal_id: UUID | None = None
    meal_name: str | None = None
    consumed_at: DateTimeValue
    created_at: DateTimeValue
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
uv run pytest tests/test_food_entry_model.py -v
```

Expected: all three new tests PASS. Existing tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add src/diet_tracker_server/models/entries.py tests/test_food_entry_model.py
git commit -m "feat: add meal_id/meal_name fields to FoodEntry models"
```

---

## Task 4: Repository — extend response columns and insert signature

**Files:**
- Modify: `src/diet_tracker_server/repositories/entries.py`

- [ ] **Step 1: Add the new columns to `_food_entry_response_columns`**

Locate `_food_entry_response_columns` (around line 24). Insert two lines before `food_entries.c.consumed_at`:

```python
def _food_entry_response_columns() -> tuple[Any, ...]:
    return (
        food_entries.c.id,
        food_entries.c.daily_log_id,
        food_entries.c.user_key,
        food_entries.c.entry_group_id,
        food_entries.c.display_name,
        food_entries.c.quantity_text,
        food_entries.c.normalized_quantity_value,
        food_entries.c.normalized_quantity_unit,
        food_entries.c.usda_fdc_id,
        food_entries.c.usda_description,
        food_entries.c.custom_food_id,
        food_entries.c.calories,
        food_entries.c.protein_g,
        food_entries.c.carbs_g,
        food_entries.c.fat_g,
        food_entries.c.meal_id,
        food_entries.c.meal_name,
        food_entries.c.consumed_at,
        food_entries.c.created_at,
    )
```

- [ ] **Step 2: Extend `create_food_entry` to accept and persist the new fields**

Update the `create_food_entry` method (around line 109). Add two parameters and two `values()` keys:

```python
    async def create_food_entry(
        self,
        entry_id: uuid.UUID,
        daily_log_id: str,
        user_key: str,
        entry_group_id: uuid.UUID,
        display_name: str,
        quantity_text: str,
        normalized_quantity_value: float | None,
        normalized_quantity_unit: str | None,
        usda_fdc_id: int | None,
        usda_description: str | None,
        custom_food_id: UUID | None,
        calories: int,
        protein_g: float,
        carbs_g: float,
        fat_g: float,
        consumed_at: DateTimeValue,
        meal_id: UUID | None = None,
        meal_name: str | None = None,
    ) -> dict[str, Any]:
        stmt = (
            pg_insert(food_entries)
            .values(
                id=entry_id,
                daily_log_id=daily_log_id,
                user_key=user_key,
                entry_group_id=entry_group_id,
                display_name=display_name,
                quantity_text=quantity_text,
                normalized_quantity_value=normalized_quantity_value,
                normalized_quantity_unit=normalized_quantity_unit,
                usda_fdc_id=usda_fdc_id,
                usda_description=usda_description,
                custom_food_id=custom_food_id,
                calories=calories,
                protein_g=protein_g,
                carbs_g=carbs_g,
                fat_g=fat_g,
                consumed_at=consumed_at,
                meal_id=meal_id,
                meal_name=meal_name,
            )
            .returning(*_food_entry_response_columns())
        )
        result = await self._session.execute(stmt)
        row = result.mappings().one()
        return dict(row)
```

- [ ] **Step 3: Run the existing repo/integration tests to make sure nothing regressed**

```bash
TEST_DATABASE_URL=postgresql+psycopg://localhost/diet_test uv run pytest tests/integration/test_repositories.py -v
```

Expected: PASS. The new optional kwargs don't change call sites yet.

- [ ] **Step 4: Commit**

```bash
git add src/diet_tracker_server/repositories/entries.py
git commit -m "feat: thread meal_id/meal_name through entries repo"
```

---

## Task 5: Entries service — pass-through

**Files:**
- Modify: `src/diet_tracker_server/services/entries_service.py`

- [ ] **Step 1: Pass the new fields from each `FoodEntryCreate` into the repo**

Locate `_create_entries` (around line 41). In the `create_food_entry` call (around line 56), append two kwargs:

```python
        created_rows.append(
            await entries_repo.create_food_entry(
                entry_id=uuid.uuid4(),
                daily_log_id=current_daily_log_id,
                user_key=user_key,
                entry_group_id=batch_entry_group_id,
                display_name=item.display_name,
                quantity_text=item.quantity_text,
                normalized_quantity_value=item.normalized_quantity_value,
                normalized_quantity_unit=item.normalized_quantity_unit,
                usda_fdc_id=item.usda_fdc_id,
                usda_description=item.usda_description,
                custom_food_id=item.custom_food_id,
                calories=item.calories,
                protein_g=item.protein_g,
                carbs_g=item.carbs_g,
                fat_g=item.fat_g,
                consumed_at=consumed_at,
                meal_id=item.meal_id,
                meal_name=item.meal_name,
            )
        )
```

- [ ] **Step 2: Run the entries service tests**

```bash
TEST_DATABASE_URL=postgresql+psycopg://localhost/diet_test uv run pytest tests/integration/test_repositories.py tests/test_app.py -v
```

Expected: PASS. Manual entries will continue to have NULL for the new fields because callers don't supply them.

- [ ] **Step 3: Commit**

```bash
git add src/diet_tracker_server/services/entries_service.py
git commit -m "feat: pass meal_id/meal_name from FoodEntryCreate into repo"
```

---

## Task 6: `log_meal` — populate the meal link

**Files:**
- Modify: `src/diet_tracker_server/services/meals_service.py`
- Test: `tests/integration/test_meals_and_memory.py`

- [ ] **Step 1: Extend the existing `log_meal` integration test to assert the link**

Open `tests/integration/test_meals_and_memory.py`. Replace the body of `test_log_meal_expands_into_food_entries` (currently ending around line 230) with a stronger version:

```python
@pytest.mark.asyncio
async def test_log_meal_expands_into_food_entries(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)

    payload = MealCreate(
        name="My Breakfast",
        notes="weekday default",
        items=[
            MealItemCreate(
                display_name="oats",
                quantity_text="1 bowl",
                usda_fdc_id=200001,
                usda_description="Oats",
                calories=300,
                protein_g=10,
                carbs_g=50,
                fat_g=5,
            ),
            MealItemCreate(
                display_name="milk",
                quantity_text="1 cup",
                usda_fdc_id=200002,
                usda_description="Milk",
                calories=100,
                protein_g=8,
                carbs_g=12,
                fat_g=3,
            ),
        ],
    )
    async with transaction(session):
        meal_row, item_rows = await create_meal_with_items(
            session=session, user_key=user_key, payload=payload, now=now
        )
    assert len(item_rows) == 2
    assert [r["position"] for r in item_rows] == [0, 1]

    created_rows, day_rows = await log_meal(
        session=session, user_key=user_key, meal_id=meal_row["id"], now=now
    )
    assert len(created_rows) == 2
    assert all(r["entry_group_id"] == created_rows[0]["entry_group_id"] for r in created_rows)
    total_calories = sum(int(r["calories"]) for r in day_rows)
    assert total_calories == 400

    # New: meal link is stamped on every created row.
    assert all(r["meal_id"] == meal_row["id"] for r in created_rows)
    assert all(r["meal_name"] == "My Breakfast" for r in created_rows)
```

- [ ] **Step 2: Add a test that manual entry creation leaves the link NULL**

Append to the same file (after the existing tests, preserving imports already in the file):

```python
@pytest.mark.asyncio
async def test_manual_entry_has_null_meal_link(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    log_date = now.date()
    entries_repo = EntriesRepository(session)

    async with transaction(session):
        log_id = entries_repo.daily_log_id(user_key=user_key, log_date=log_date)
        await entries_repo.ensure_daily_log(log_id, user_key, log_date)
        row = await entries_repo.create_food_entry(
            entry_id=uuid.uuid4(),
            daily_log_id=log_id,
            user_key=user_key,
            entry_group_id=uuid.uuid4(),
            display_name="ad-hoc",
            quantity_text="1",
            normalized_quantity_value=None,
            normalized_quantity_unit=None,
            usda_fdc_id=200003,
            usda_description="ad-hoc usda",
            custom_food_id=None,
            calories=50,
            protein_g=1,
            carbs_g=10,
            fat_g=2,
            consumed_at=now,
        )

    assert row["meal_id"] is None
    assert row["meal_name"] is None
```

If `EntriesRepository` is not already imported in this file, add to the existing imports:

```python
from diet_tracker_server.repositories.entries import EntriesRepository
```

(Check the top of the file — it already imports `EntriesRepository` for the existing `test_delete_custom_food_blocked_when_referenced` test, so this is likely a no-op.)

- [ ] **Step 3: Run tests to verify they fail**

```bash
TEST_DATABASE_URL=postgresql+psycopg://localhost/diet_test uv run pytest tests/integration/test_meals_and_memory.py -v -k "log_meal_expands or manual_entry_has_null"
```

Expected: `test_log_meal_expands_into_food_entries` FAILS on the new assertions (returned rows have `meal_id is None` because `log_meal` does not yet stamp it). `test_manual_entry_has_null_meal_link` PASSES (the field already defaults to NULL via the new repo signature).

- [ ] **Step 4: Update `log_meal` to stamp `meal_id` and `meal_name`**

In `src/diet_tracker_server/services/meals_service.py`, edit the `entry_items` list comprehension inside `log_meal` (currently around line 124). Add the two new fields:

```python
        effective_consumed_at = consumed_at or now
        meal_name = meal["name"]
        entry_items = [
            FoodEntryCreate(
                display_name=item["display_name"],
                quantity_text=item["quantity_text"],
                normalized_quantity_value=_optional_float(item["normalized_quantity_value"]),
                normalized_quantity_unit=item["normalized_quantity_unit"],
                usda_fdc_id=item["usda_fdc_id"],
                usda_description=item["usda_description"],
                custom_food_id=item["custom_food_id"],
                calories=int(item["calories"]),
                protein_g=float(item["protein_g"]),
                carbs_g=float(item["carbs_g"]),
                fat_g=float(item["fat_g"]),
                consumed_at=effective_consumed_at,
                meal_id=meal_id,
                meal_name=meal_name,
            )
            for item in items
        ]
```

`meal["name"]` reads the source meal's name at log time and snapshots it onto every created entry. Renaming the meal later does not retroactively mutate historical entries.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
TEST_DATABASE_URL=postgresql+psycopg://localhost/diet_test uv run pytest tests/integration/test_meals_and_memory.py -v
```

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add src/diet_tracker_server/services/meals_service.py tests/integration/test_meals_and_memory.py
git commit -m "feat: log_meal stamps meal_id/meal_name on created entries"
```

---

## Task 7: Edge-case integration tests (rename / delete)

**Files:**
- Modify: `tests/integration/test_meals_and_memory.py`

- [ ] **Step 1: Add a test confirming meal rename does not mutate historical entries**

Append to `tests/integration/test_meals_and_memory.py`:

```python
@pytest.mark.asyncio
async def test_meal_rename_does_not_mutate_historical_entries(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)

    payload = MealCreate(
        name="Original Name",
        notes=None,
        items=[
            MealItemCreate(
                display_name="oats",
                quantity_text="1 bowl",
                usda_fdc_id=200001,
                usda_description="Oats",
                calories=300,
                protein_g=10,
                carbs_g=50,
                fat_g=5,
            ),
        ],
    )
    async with transaction(session):
        meal_row, _ = await create_meal_with_items(
            session=session, user_key=user_key, payload=payload, now=now
        )

    created_rows, _ = await log_meal(
        session=session, user_key=user_key, meal_id=meal_row["id"], now=now
    )
    assert created_rows[0]["meal_name"] == "Original Name"

    # Rename the meal (direct UPDATE — covers the "what if a write happens later" case).
    from sqlalchemy import update
    from diet_tracker_server.repositories.tables import meals as meals_table

    async with transaction(session):
        await session.execute(
            update(meals_table)
            .where(meals_table.c.id == meal_row["id"])
            .values(name="Renamed", normalized_name="renamed")
        )

    # Re-read the entry; its meal_name must still read "Original Name".
    entries_repo = EntriesRepository(session)
    log_id = entries_repo.daily_log_id(user_key=user_key, log_date=now.date())
    rows = await entries_repo.list_entries_by_daily_log_id(log_id)
    assert rows[0]["meal_id"] == meal_row["id"]
    assert rows[0]["meal_name"] == "Original Name"
```

- [ ] **Step 2: Add a test confirming meal deletion sets `meal_id` NULL but preserves `meal_name`**

Append to the same file:

```python
@pytest.mark.asyncio
async def test_meal_delete_sets_meal_id_null_keeps_meal_name(session: AsyncSession) -> None:
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)

    payload = MealCreate(
        name="Doomed Meal",
        notes=None,
        items=[
            MealItemCreate(
                display_name="oats",
                quantity_text="1 bowl",
                usda_fdc_id=200001,
                usda_description="Oats",
                calories=300,
                protein_g=10,
                carbs_g=50,
                fat_g=5,
            ),
        ],
    )
    async with transaction(session):
        meal_row, _ = await create_meal_with_items(
            session=session, user_key=user_key, payload=payload, now=now
        )

    await log_meal(
        session=session, user_key=user_key, meal_id=meal_row["id"], now=now
    )

    # Delete the meal directly through the repo.
    repo = MealsRepository(session)
    async with transaction(session):
        deleted = await repo.delete_meal(meal_row["id"], user_key)
    assert deleted is True

    entries_repo = EntriesRepository(session)
    log_id = entries_repo.daily_log_id(user_key=user_key, log_date=now.date())
    rows = await entries_repo.list_entries_by_daily_log_id(log_id)
    assert rows[0]["meal_id"] is None
    assert rows[0]["meal_name"] == "Doomed Meal"
```

`MealsRepository.delete_meal(meal_id: UUID, user_key: str) -> bool` is defined in `src/diet_tracker_server/repositories/meals.py:226` — use it as shown above.

- [ ] **Step 3: Run the new tests**

```bash
TEST_DATABASE_URL=postgresql+psycopg://localhost/diet_test uv run pytest tests/integration/test_meals_and_memory.py -v -k "rename_does_not_mutate or delete_sets_meal_id_null"
```

Expected: PASS. The denormalization decision (independent `meal_id` vs `meal_name` columns; FK with `ON DELETE SET NULL`; no CHECK linking them) makes both behaviors hold without further code changes.

- [ ] **Step 4: Run the full test suite**

```bash
uv run pytest tests/ -v
```

```bash
TEST_DATABASE_URL=postgresql+psycopg://localhost/diet_test uv run pytest -m integration -v
```

Expected: PASS in both runs.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/test_meals_and_memory.py
git commit -m "test: cover meal rename/delete preserves entry meal_name and nullifies meal_id"
```

---

## Task 8: MCP layer — verify forward-compat

**Files:**
- Verify: `src/diet_tracker_server/mcp/server.py`

The MCP server constructs `FoodEntryResponse(**row)` from row dicts at five sites (`mcp/server.py:351, 360, 400, 962, 971`). Now that the underlying repo selects `meal_id` and `meal_name` and the model has matching fields, these construction sites pick up the new fields automatically. No code change required.

- [ ] **Step 1: Confirm by grep that no `FoodEntryResponse` construction site spreads a curated dict that would omit the new fields**

```bash
rg "FoodEntryResponse\(" src/diet_tracker_server/mcp/
```

Expected: every match shows `**row` spreading. If any match constructs by named kwargs, that site needs explicit additions for `meal_id`/`meal_name`. Currently there are none.

- [ ] **Step 2: Run MCP tool tests**

```bash
uv run pytest tests/test_mcp_tools.py -v
```

Expected: PASS.

- [ ] **Step 3: Commit (only if MCP tests required tweaks; otherwise skip)**

```bash
git add src/diet_tracker_server/mcp/
git commit -m "chore: confirm MCP entry responses surface meal_id/meal_name"
```

If no changes were needed, no commit.

---

## Final verification

- [ ] **Step 1: All tests green**

```bash
uv run pytest tests/ -v
TEST_DATABASE_URL=postgresql+psycopg://localhost/diet_test uv run pytest -m integration -v
```

Expected: PASS.

- [ ] **Step 2: Smoke against a local server**

```bash
uv run uvicorn diet_tracker_server.app:app --port 8787 --reload
```

In a second terminal:

```bash
# Adjust the bearer token for your local session.
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8787/days/$(date +%F) | jq '.entries[0] | keys'
```

Expected: the JSON keys list includes `meal_id` and `meal_name`. For a manual entry, both values are `null`. For a meal-logged entry, both are populated.

---

## Self-review notes

- All spec sections covered: schema (Task 1, 2), models (Task 3), repo (Task 4), service pass-through (Task 5), `log_meal` stamp (Task 6), edge cases for rename/delete (Task 7), MCP forward-compat (Task 8).
- No placeholders, no "implement later".
- Type/property names consistent across tasks: `meal_id`, `meal_name`, `FoodEntryCreate`, `FoodEntryResponse`, `EntriesRepository.create_food_entry`.
- Sequencing: each task can ship as its own commit; ordering matters because Task 5 depends on the kwargs added in Task 4, and Task 6 depends on the model fields added in Task 3. Tasks 7 and 8 are independent.
