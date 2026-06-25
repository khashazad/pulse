# Activity Import (Apple Health + Hevy) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import Apple Health workout sessions + daily activity summaries and Hevy strength sets from manual export files into the Pulse Postgres database, idempotently, via a local script.

**Architecture:** Four new `user_key`-scoped tables (`apple_workouts`, `strength_workouts`, `strength_sets`, `daily_activity`). A new `pulse_server.activity` package holds plain dataclasses, deterministic-id helpers, two pure parsers (Hevy CSV, Apple XML), and an async upsert repository. A thin `scripts/import_health_data.py` CLI wires parse → upsert and prints per-table inserted/updated counts. Re-running updates rows in place via Postgres `ON CONFLICT DO UPDATE` keyed on deterministic UUID5 ids.

**Tech Stack:** Python 3, FastAPI app's existing SQLAlchemy Core + async psycopg3 engine, `xml.etree.ElementTree.iterparse` for streaming the 1.4 GB XML, `csv.DictReader`, `pytest` / `pytest-asyncio`.

## Global Constraints

- All data scoped by `user_key`; default from `get_settings().legacy_user_key` (`"khash"`).
- Hevy local timestamps interpreted in `get_settings().timezone` (`"America/Toronto"`); Apple timestamps carry explicit offsets.
- Deterministic ids use `uuid.uuid5(uuid.NAMESPACE_URL, ...)`, mirroring `pulse_server/log_ids.py`.
- `schema.sql` is the single source of truth (idempotent guarded DDL); `repositories/tables.py` is kept in sync by hand.
- Hevy weights stay in **lbs** — no unit conversion.
- Apple Health body-mass / raw `<Record>` samples are **ignored** — never parsed or stored.
- DB access only through `pulse_server.db` (`init_pool`, `get_session`, `transaction`, `close_pool`); no module constructs its own engine.
- Numeric DB columns use SQLAlchemy `Numeric`; integer counts use `Integer`.

---

## File Structure

- `server/schema.sql` — append 4 idempotent `CREATE TABLE IF NOT EXISTS` blocks + indexes.
- `server/src/pulse_server/repositories/tables.py` — append 4 `Table` objects; extend module docstring.
- `server/src/pulse_server/activity/__init__.py` — new package marker.
- `server/src/pulse_server/activity/models.py` — frozen dataclasses (`AppleWorkout`, `DailyActivity`, `StrengthWorkout`, `StrengthSet`).
- `server/src/pulse_server/activity/ids.py` — `apple_workout_id`, `strength_workout_id`, `strength_set_id`.
- `server/src/pulse_server/activity/hevy_parser.py` — `parse_hevy_csv`.
- `server/src/pulse_server/activity/apple_parser.py` — `parse_apple_export` (single streaming pass).
- `server/src/pulse_server/activity/repository.py` — async upsert functions returning `(inserted, updated)`.
- `server/src/pulse_server/scripts/__init__.py` — new package marker.
- `server/src/pulse_server/scripts/import_health_data.py` — argparse CLI.
- Tests under `server/tests/`: `test_activity_ids.py`, `test_hevy_parser.py`, `test_apple_parser.py`, and integration `tests/integration/test_activity_repository.py`, `tests/integration/test_import_health_data.py`, plus fixtures under `tests/fixtures/activity/`.

---

### Task 1: Schema + table definitions

**Files:**
- Modify: `server/schema.sql` (append at end, before the final `do $$ ... revoke ...` grants block is fine — append after it instead, at EOF)
- Modify: `server/src/pulse_server/repositories/tables.py` (append new `Table` objects after `weight_entries`; extend docstring list)
- Test: `server/tests/test_activity_tables.py`

**Interfaces:**
- Produces: SQLAlchemy `Table` objects `apple_workouts`, `strength_workouts`, `strength_sets`, `daily_activity` importable from `pulse_server.repositories.tables`.

- [ ] **Step 1: Write the failing test**

Create `server/tests/test_activity_tables.py`:

```python
"""Unit checks that the activity tables are declared and column-complete.

These guard against drift between schema.sql and the hand-maintained
SQLAlchemy Core definitions for the new activity-import tables.
"""

from __future__ import annotations

from pulse_server.repositories.tables import (
    apple_workouts,
    daily_activity,
    strength_sets,
    strength_workouts,
)


def test_apple_workouts_columns():
    cols = set(apple_workouts.c.keys())
    assert {
        "id", "user_key", "activity_type", "source_name", "start_time",
        "end_time", "duration_min", "active_energy_cal", "basal_energy_cal",
        "avg_heart_rate", "max_heart_rate", "distance_km", "step_count",
        "flights_climbed", "indoor", "elevation_ascended_m", "avg_mets",
        "temperature_f", "humidity_pct", "timezone", "route_gpx_path",
        "linked_strength_workout_id", "created_at",
    } == cols


def test_strength_tables_columns():
    assert {"id", "user_key", "title", "start_time", "end_time",
            "description", "created_at"} == set(strength_workouts.c.keys())
    assert {
        "id", "strength_workout_id", "user_key", "exercise_title",
        "superset_id", "exercise_notes", "set_index", "set_type",
        "weight_lbs", "reps", "distance_km", "duration_seconds", "rpe",
        "created_at",
    } == set(strength_sets.c.keys())


def test_daily_activity_columns():
    assert {
        "user_key", "date", "active_energy_cal", "active_energy_goal",
        "exercise_minutes", "exercise_goal", "stand_hours", "stand_goal",
        "created_at",
    } == set(daily_activity.c.keys())
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && uv run pytest tests/test_activity_tables.py -v`
Expected: FAIL with `ImportError: cannot import name 'apple_workouts'`.

- [ ] **Step 3: Append the `Table` definitions**

In `server/src/pulse_server/repositories/tables.py`, after the `weight_entries` table block (around line 335), append:

```python
apple_workouts = Table(
    "apple_workouts",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True),
    Column("user_key", Text, nullable=False),
    Column("activity_type", Text, nullable=False),
    Column("source_name", Text, nullable=True),
    Column("start_time", DateTime(timezone=True), nullable=False),
    Column("end_time", DateTime(timezone=True), nullable=False),
    Column("duration_min", Numeric, nullable=True),
    Column("active_energy_cal", Numeric, nullable=True),
    Column("basal_energy_cal", Numeric, nullable=True),
    Column("avg_heart_rate", Numeric, nullable=True),
    Column("max_heart_rate", Numeric, nullable=True),
    Column("distance_km", Numeric, nullable=True),
    Column("step_count", Integer, nullable=True),
    Column("flights_climbed", Integer, nullable=True),
    Column("indoor", Boolean, nullable=True),
    Column("elevation_ascended_m", Numeric, nullable=True),
    Column("avg_mets", Numeric, nullable=True),
    Column("temperature_f", Numeric, nullable=True),
    Column("humidity_pct", Numeric, nullable=True),
    Column("timezone", Text, nullable=True),
    Column("route_gpx_path", Text, nullable=True),
    Column("linked_strength_workout_id", UUID(as_uuid=True), nullable=True),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Index("idx_apple_workouts_user_key_start_time", "user_key", "start_time"),
)

strength_workouts = Table(
    "strength_workouts",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True),
    Column("user_key", Text, nullable=False),
    Column("title", Text, nullable=False),
    Column("start_time", DateTime(timezone=True), nullable=False),
    Column("end_time", DateTime(timezone=True), nullable=False),
    Column("description", Text, nullable=True),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Index("idx_strength_workouts_user_key_start_time", "user_key", "start_time"),
)

strength_sets = Table(
    "strength_sets",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True),
    Column(
        "strength_workout_id",
        UUID(as_uuid=True),
        ForeignKey("strength_workouts.id", ondelete="CASCADE"),
        nullable=False,
    ),
    Column("user_key", Text, nullable=False),
    Column("exercise_title", Text, nullable=False),
    Column("superset_id", Text, nullable=True),
    Column("exercise_notes", Text, nullable=True),
    Column("set_index", Integer, nullable=False),
    Column("set_type", Text, nullable=True),
    Column("weight_lbs", Numeric, nullable=True),
    Column("reps", Integer, nullable=True),
    Column("distance_km", Numeric, nullable=True),
    Column("duration_seconds", Integer, nullable=True),
    Column("rpe", Numeric, nullable=True),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Index("idx_strength_sets_workout_id", "strength_workout_id"),
)

daily_activity = Table(
    "daily_activity",
    metadata,
    Column("user_key", Text, nullable=False),
    Column("date", Date, nullable=False),
    Column("active_energy_cal", Numeric, nullable=False),
    Column("active_energy_goal", Numeric, nullable=False),
    Column("exercise_minutes", Integer, nullable=False),
    Column("exercise_goal", Integer, nullable=False),
    Column("stand_hours", Integer, nullable=False),
    Column("stand_goal", Integer, nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    PrimaryKeyConstraint("user_key", "date", name="daily_activity_pkey"),
)
```

Add `PrimaryKeyConstraint` to the existing `from sqlalchemy import (...)` block in this file (insert alphabetically near `Numeric`).

- [ ] **Step 4: Append the DDL to `schema.sql`**

At the end of `server/schema.sql`, append:

```sql
-- ===== Activity import: Apple Health workouts + Hevy strength + daily activity =====

create table if not exists apple_workouts (
  id uuid primary key,
  user_key text not null,
  activity_type text not null,
  source_name text,
  start_time timestamptz not null,
  end_time timestamptz not null,
  duration_min numeric,
  active_energy_cal numeric,
  basal_energy_cal numeric,
  avg_heart_rate numeric,
  max_heart_rate numeric,
  distance_km numeric,
  step_count integer,
  flights_climbed integer,
  indoor boolean,
  elevation_ascended_m numeric,
  avg_mets numeric,
  temperature_f numeric,
  humidity_pct numeric,
  timezone text,
  route_gpx_path text,
  linked_strength_workout_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists idx_apple_workouts_user_key_start_time
  on apple_workouts (user_key, start_time);

create table if not exists strength_workouts (
  id uuid primary key,
  user_key text not null,
  title text not null,
  start_time timestamptz not null,
  end_time timestamptz not null,
  description text,
  created_at timestamptz not null default now()
);
create index if not exists idx_strength_workouts_user_key_start_time
  on strength_workouts (user_key, start_time);

create table if not exists strength_sets (
  id uuid primary key,
  strength_workout_id uuid not null references strength_workouts (id) on delete cascade,
  user_key text not null,
  exercise_title text not null,
  superset_id text,
  exercise_notes text,
  set_index integer not null,
  set_type text,
  weight_lbs numeric,
  reps integer,
  distance_km numeric,
  duration_seconds integer,
  rpe numeric,
  created_at timestamptz not null default now()
);
create index if not exists idx_strength_sets_workout_id
  on strength_sets (strength_workout_id);

create table if not exists daily_activity (
  user_key text not null,
  date date not null,
  active_energy_cal numeric not null,
  active_energy_goal numeric not null,
  exercise_minutes integer not null,
  exercise_goal integer not null,
  stand_hours integer not null,
  stand_goal integer not null,
  created_at timestamptz not null default now(),
  primary key (user_key, date)
);
```

> Note: place this block BEFORE the trailing `do $$ ... revoke all on all tables ... $$;` grants block so the new tables are covered by the Data-API revoke. If that block is at EOF, insert this DDL immediately above it.

- [ ] **Step 5: Extend the `tables.py` module docstring**

In the docstring "Tables defined here" list, add four bullets:

```
- ``apple_workouts`` — one row per Apple Health workout session (summary stats only).
- ``strength_workouts`` / ``strength_sets`` — Hevy session headers and their sets.
- ``daily_activity`` — per-day Apple activity summary (active energy, exercise, stand).
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd server && uv run pytest tests/test_activity_tables.py -v`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add server/schema.sql server/src/pulse_server/repositories/tables.py server/tests/test_activity_tables.py
git commit -m "feat(server): add activity-import tables (apple_workouts, strength_*, daily_activity)"
```

---

### Task 2: Dataclasses + deterministic ids

**Files:**
- Create: `server/src/pulse_server/activity/__init__.py`
- Create: `server/src/pulse_server/activity/models.py`
- Create: `server/src/pulse_server/activity/ids.py`
- Test: `server/tests/test_activity_ids.py`

**Interfaces:**
- Produces:
  - `models.AppleWorkout`, `models.DailyActivity`, `models.StrengthWorkout`, `models.StrengthSet` (frozen dataclasses; fields exactly as below).
  - `ids.apple_workout_id(user_key: str, start_time: datetime, activity_type: str) -> str`
  - `ids.strength_workout_id(user_key: str, title: str, start_time: datetime) -> str`
  - `ids.strength_set_id(workout_id: str, exercise_title: str, set_index: int) -> str`

- [ ] **Step 1: Write the failing test**

Create `server/tests/test_activity_ids.py`:

```python
"""Determinism checks for activity-import UUID5 derivations."""

from __future__ import annotations

from datetime import datetime, timezone

from pulse_server.activity import ids


def test_apple_workout_id_is_deterministic():
    t = datetime(2026, 6, 12, 8, 34, tzinfo=timezone.utc)
    a = ids.apple_workout_id("khash", t, "TraditionalStrengthTraining")
    b = ids.apple_workout_id("khash", t, "TraditionalStrengthTraining")
    assert a == b
    assert len(a) == 36  # canonical UUID string


def test_apple_workout_id_varies_by_input():
    t = datetime(2026, 6, 12, 8, 34, tzinfo=timezone.utc)
    assert ids.apple_workout_id("khash", t, "Yoga") != ids.apple_workout_id(
        "khash", t, "Cycling"
    )


def test_strength_set_id_depends_on_workout_and_index():
    wid = ids.strength_workout_id(
        "khash", "Chest Day", datetime(2026, 6, 12, 7, 26, tzinfo=timezone.utc)
    )
    s0 = ids.strength_set_id(wid, "Incline Dumbbell Press", 0)
    s1 = ids.strength_set_id(wid, "Incline Dumbbell Press", 1)
    assert s0 != s1
    assert s0 == ids.strength_set_id(wid, "Incline Dumbbell Press", 0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && uv run pytest tests/test_activity_ids.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'pulse_server.activity'`.

- [ ] **Step 3: Create the package + models**

Create `server/src/pulse_server/activity/__init__.py`:

```python
"""Activity import: parse Apple Health + Hevy exports into Postgres."""
```

Create `server/src/pulse_server/activity/models.py`:

```python
"""Plain value types emitted by the activity parsers and consumed by the
activity repository. Decoupled from both file formats and the DB layer."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date as DateValue
from datetime import datetime as DateTimeValue


@dataclass(frozen=True)
class AppleWorkout:
    """One Apple Health ``<Workout>`` session summary."""

    user_key: str
    activity_type: str
    source_name: str | None
    start_time: DateTimeValue
    end_time: DateTimeValue
    duration_min: float | None
    active_energy_cal: float | None
    basal_energy_cal: float | None
    avg_heart_rate: float | None
    max_heart_rate: float | None
    distance_km: float | None
    step_count: int | None
    flights_climbed: int | None
    indoor: bool | None
    elevation_ascended_m: float | None
    avg_mets: float | None
    temperature_f: float | None
    humidity_pct: float | None
    timezone: str | None
    route_gpx_path: str | None


@dataclass(frozen=True)
class DailyActivity:
    """One Apple Health ``<ActivitySummary>`` day."""

    user_key: str
    date: DateValue
    active_energy_cal: float
    active_energy_goal: float
    exercise_minutes: int
    exercise_goal: int
    stand_hours: int
    stand_goal: int


@dataclass(frozen=True)
class StrengthWorkout:
    """A Hevy session header (one per ``(title, start_time)``)."""

    user_key: str
    title: str
    start_time: DateTimeValue
    end_time: DateTimeValue
    description: str | None


@dataclass(frozen=True)
class StrengthSet:
    """One Hevy set. ``workout_title`` + ``workout_start_time`` let the
    repository recompute the parent ``strength_workouts`` id for the FK."""

    user_key: str
    workout_title: str
    workout_start_time: DateTimeValue
    exercise_title: str
    superset_id: str | None
    exercise_notes: str | None
    set_index: int
    set_type: str | None
    weight_lbs: float | None
    reps: int | None
    distance_km: float | None
    duration_seconds: int | None
    rpe: float | None
```

- [ ] **Step 4: Create the id helpers**

Create `server/src/pulse_server/activity/ids.py`:

```python
"""Deterministic UUID5 ids for activity rows, mirroring ``log_ids.py`` so
imports upsert idempotently without a prior read."""

from __future__ import annotations

import uuid
from datetime import datetime as DateTimeValue


def apple_workout_id(user_key: str, start_time: DateTimeValue, activity_type: str) -> str:
    """Stable id for an Apple workout from its owner, start, and activity type.

    **Inputs:**
    - user_key (str): Owning user key.
    - start_time (datetime): Workout start (tz-aware).
    - activity_type (str): Prefix-stripped activity type.

    **Outputs:**
    - str: Canonical UUID5 string.
    """
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{user_key}:{start_time.isoformat()}:{activity_type}"))


def strength_workout_id(user_key: str, title: str, start_time: DateTimeValue) -> str:
    """Stable id for a Hevy session from owner, title, and start.

    **Inputs:**
    - user_key (str): Owning user key.
    - title (str): Hevy workout title.
    - start_time (datetime): Session start (tz-aware).

    **Outputs:**
    - str: Canonical UUID5 string.
    """
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{user_key}:{title}:{start_time.isoformat()}"))


def strength_set_id(workout_id: str, exercise_title: str, set_index: int) -> str:
    """Stable id for a Hevy set within its parent workout.

    **Inputs:**
    - workout_id (str): Parent ``strength_workouts`` id.
    - exercise_title (str): Exercise name.
    - set_index (int): Set ordinal within the exercise.

    **Outputs:**
    - str: Canonical UUID5 string.
    """
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{workout_id}:{exercise_title}:{set_index}"))
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd server && uv run pytest tests/test_activity_ids.py -v`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add server/src/pulse_server/activity/
git add server/tests/test_activity_ids.py
git commit -m "feat(server): activity dataclasses + deterministic id helpers"
```

---

### Task 3: Hevy CSV parser

**Files:**
- Create: `server/src/pulse_server/activity/hevy_parser.py`
- Create: `server/tests/fixtures/activity/hevy_sample.csv`
- Test: `server/tests/test_hevy_parser.py`

**Interfaces:**
- Consumes: `models.StrengthWorkout`, `models.StrengthSet`.
- Produces: `parse_hevy_csv(path: str | Path, *, user_key: str, tz: tzinfo) -> tuple[list[StrengthWorkout], list[StrengthSet]]`. Workouts are de-duplicated by `(title, start_time)`; one `StrengthSet` per CSV row. Blank numeric cells → `None`.

- [ ] **Step 1: Create the fixture**

Create `server/tests/fixtures/activity/hevy_sample.csv` (verbatim — note the two rows share one session, the third is a different session):

```csv
"title","start_time","end_time","description","exercise_title","superset_id","exercise_notes","set_index","set_type","weight_lbs","reps","distance_km","duration_seconds","rpe"
"Chest Day","12 Jun 2026, 07:26","12 Jun 2026, 08:34","focus","Incline Dumbbell Press",,"",0,"warmup",55,15,,,
"Chest Day","12 Jun 2026, 07:26","12 Jun 2026, 08:34","focus","Incline Dumbbell Press",,"",1,"normal",65,12,,,8
"Morning Cardio","12 Jun 2026, 08:34","12 Jun 2026, 08:55","","Stair Machine (Steps)",,"",0,"normal",,,,1206,
```

- [ ] **Step 2: Write the failing test**

Create `server/tests/test_hevy_parser.py`:

```python
"""Unit tests for the Hevy CSV parser."""

from __future__ import annotations

from pathlib import Path
from zoneinfo import ZoneInfo

from pulse_server.activity.hevy_parser import parse_hevy_csv

FIXTURE = Path(__file__).parent / "fixtures" / "activity" / "hevy_sample.csv"
TZ = ZoneInfo("America/Toronto")


def test_groups_rows_into_sessions():
    workouts, sets = parse_hevy_csv(FIXTURE, user_key="khash", tz=TZ)
    assert len(workouts) == 2  # Chest Day + Morning Cardio
    assert len(sets) == 3
    titles = {w.title for w in workouts}
    assert titles == {"Chest Day", "Morning Cardio"}


def test_parses_times_in_timezone():
    workouts, _ = parse_hevy_csv(FIXTURE, user_key="khash", tz=TZ)
    chest = next(w for w in workouts if w.title == "Chest Day")
    assert chest.start_time.year == 2026
    assert chest.start_time.hour == 7
    assert chest.start_time.tzinfo is not None
    assert chest.start_time.utcoffset() is not None


def test_blank_numeric_cells_become_none():
    _, sets = parse_hevy_csv(FIXTURE, user_key="khash", tz=TZ)
    stair = next(s for s in sets if s.exercise_title == "Stair Machine (Steps)")
    assert stair.weight_lbs is None
    assert stair.reps is None
    assert stair.duration_seconds == 1206
    warmup = next(s for s in sets if s.set_index == 0 and s.exercise_title == "Incline Dumbbell Press")
    assert warmup.weight_lbs == 55.0
    assert warmup.rpe is None
    normal = next(s for s in sets if s.set_index == 1 and s.exercise_title == "Incline Dumbbell Press")
    assert normal.rpe == 8.0
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd server && uv run pytest tests/test_hevy_parser.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'pulse_server.activity.hevy_parser'`.

- [ ] **Step 4: Implement the parser**

Create `server/src/pulse_server/activity/hevy_parser.py`:

```python
"""Parse a Hevy CSV export into strength-workout and strength-set value types."""

from __future__ import annotations

import csv
from datetime import datetime as DateTimeValue
from datetime import tzinfo
from pathlib import Path

from pulse_server.activity.models import StrengthSet, StrengthWorkout

_HEVY_TIME_FORMAT = "%d %b %Y, %H:%M"


def _opt_float(value: str | None) -> float | None:
    """Convert a possibly-blank CSV cell to float or None.

    **Inputs:**
    - value (str | None): Raw cell text.

    **Outputs:**
    - float | None: Parsed float, or None when blank/missing.
    """
    if value is None or value.strip() == "":
        return None
    return float(value)


def _opt_int(value: str | None) -> int | None:
    """Convert a possibly-blank CSV cell to int or None.

    **Inputs:**
    - value (str | None): Raw cell text.

    **Outputs:**
    - int | None: Parsed int, or None when blank/missing.
    """
    f = _opt_float(value)
    return None if f is None else int(f)


def _parse_time(value: str, tz: tzinfo) -> DateTimeValue:
    """Parse a Hevy local timestamp and attach the configured timezone.

    **Inputs:**
    - value (str): Timestamp like ``"12 Jun 2026, 08:34"``.
    - tz (tzinfo): Timezone the local time is interpreted in.

    **Outputs:**
    - datetime: Timezone-aware datetime.
    """
    return DateTimeValue.strptime(value, _HEVY_TIME_FORMAT).replace(tzinfo=tz)


def parse_hevy_csv(
    path: str | Path, *, user_key: str, tz: tzinfo
) -> tuple[list[StrengthWorkout], list[StrengthSet]]:
    """Parse a Hevy CSV export into deduplicated workouts and their sets.

    Rows sharing ``(title, start_time)`` collapse to one ``StrengthWorkout``;
    every row yields one ``StrengthSet``.

    **Inputs:**
    - path (str | Path): Path to the Hevy CSV export.
    - user_key (str): Owning user key applied to every emitted row.
    - tz (tzinfo): Timezone for interpreting Hevy local timestamps.

    **Outputs:**
    - tuple[list[StrengthWorkout], list[StrengthSet]]: Deduplicated session
      headers and the flat list of sets.
    """
    workouts: dict[tuple[str, DateTimeValue], StrengthWorkout] = {}
    sets: list[StrengthSet] = []

    with open(path, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            title = row["title"]
            start = _parse_time(row["start_time"], tz)
            end = _parse_time(row["end_time"], tz)
            key = (title, start)
            if key not in workouts:
                description = row.get("description") or None
                workouts[key] = StrengthWorkout(
                    user_key=user_key,
                    title=title,
                    start_time=start,
                    end_time=end,
                    description=description.strip() or None if description else None,
                )
            sets.append(
                StrengthSet(
                    user_key=user_key,
                    workout_title=title,
                    workout_start_time=start,
                    exercise_title=row["exercise_title"],
                    superset_id=(row.get("superset_id") or "").strip() or None,
                    exercise_notes=(row.get("exercise_notes") or "").strip() or None,
                    set_index=int(row["set_index"]),
                    set_type=(row.get("set_type") or "").strip() or None,
                    weight_lbs=_opt_float(row.get("weight_lbs")),
                    reps=_opt_int(row.get("reps")),
                    distance_km=_opt_float(row.get("distance_km")),
                    duration_seconds=_opt_int(row.get("duration_seconds")),
                    rpe=_opt_float(row.get("rpe")),
                )
            )

    return list(workouts.values()), sets
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd server && uv run pytest tests/test_hevy_parser.py -v`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add server/src/pulse_server/activity/hevy_parser.py server/tests/test_hevy_parser.py server/tests/fixtures/activity/hevy_sample.csv
git commit -m "feat(server): Hevy CSV parser"
```

---

### Task 4: Apple Health XML parser

**Files:**
- Create: `server/src/pulse_server/activity/apple_parser.py`
- Create: `server/tests/fixtures/activity/apple_sample.xml`
- Test: `server/tests/test_apple_parser.py`

**Interfaces:**
- Consumes: `models.AppleWorkout`, `models.DailyActivity`.
- Produces: `parse_apple_export(path: str | Path, *, user_key: str) -> tuple[list[AppleWorkout], list[DailyActivity]]`. Single streaming `iterparse` pass; ignores all `<Record>` samples; strips the `HKWorkoutActivityType` / `HKQuantityTypeIdentifier` prefixes; converts elevation cm→m.

- [ ] **Step 1: Create the fixture**

Create `server/tests/fixtures/activity/apple_sample.xml` (small but exercises every branch — one workout with full stats + metadata + route, one minimal workout, two activity summaries, and a stray `<Record>` that must be ignored):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<HealthData locale="en_US">
 <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="Watch" startDate="2026-06-12 08:00:00 -0400" endDate="2026-06-12 08:00:01 -0400" value="72"/>
 <Workout workoutActivityType="HKWorkoutActivityTypeTraditionalStrengthTraining" duration="68.0" durationUnit="min" sourceName="Khashayar's Apple Watch" startDate="2026-06-12 07:26:00 -0400" endDate="2026-06-12 08:34:00 -0400">
  <MetadataEntry key="HKIndoorWorkout" value="1"/>
  <MetadataEntry key="HKAverageMETs" value="6.5 kcal/hr·kg"/>
  <MetadataEntry key="HKWeatherTemperature" value="73.4 degF"/>
  <MetadataEntry key="HKWeatherHumidity" value="4300 %"/>
  <MetadataEntry key="HKTimeZone" value="America/Toronto"/>
  <MetadataEntry key="HKElevationAscended" value="8652 cm"/>
  <WorkoutStatistics type="HKQuantityTypeIdentifierActiveEnergyBurned" sum="408.38" unit="Cal"/>
  <WorkoutStatistics type="HKQuantityTypeIdentifierBasalEnergyBurned" sum="154.7" unit="Cal"/>
  <WorkoutStatistics type="HKQuantityTypeIdentifierHeartRate" average="118.2" maximum="160.0" unit="count/min"/>
  <WorkoutStatistics type="HKQuantityTypeIdentifierDistanceWalkingRunning" sum="4.82" unit="km"/>
  <WorkoutStatistics type="HKQuantityTypeIdentifierStepCount" sum="320" unit="count"/>
  <WorkoutStatistics type="HKQuantityTypeIdentifierFlightsClimbed" sum="3" unit="count"/>
  <WorkoutRoute sourceName="Watch" startDate="2026-06-12 07:26:00 -0400" endDate="2026-06-12 08:34:00 -0400">
   <FileReference path="/workout-routes/route_2026-06-12_7.26am.gpx"/>
  </WorkoutRoute>
 </Workout>
 <Workout workoutActivityType="HKWorkoutActivityTypeYoga" duration="30.0" durationUnit="min" sourceName="Watch" startDate="2026-06-13 18:00:00 -0400" endDate="2026-06-13 18:30:00 -0400">
 </Workout>
 <ActivitySummary dateComponents="2026-06-12" activeEnergyBurned="577.8" activeEnergyBurnedGoal="780" activeEnergyBurnedUnit="Cal" appleExerciseTime="55" appleExerciseTimeGoal="60" appleStandHours="7" appleStandHoursGoal="12"/>
 <ActivitySummary dateComponents="2026-06-13" activeEnergyBurned="1030.4" activeEnergyBurnedGoal="780" activeEnergyBurnedUnit="Cal" appleExerciseTime="91" appleExerciseTimeGoal="60" appleStandHours="11" appleStandHoursGoal="12"/>
</HealthData>
```

- [ ] **Step 2: Write the failing test**

Create `server/tests/test_apple_parser.py`:

```python
"""Unit tests for the streaming Apple Health export parser."""

from __future__ import annotations

from pathlib import Path

from pulse_server.activity.apple_parser import parse_apple_export

FIXTURE = Path(__file__).parent / "fixtures" / "activity" / "apple_sample.xml"


def test_parses_workouts_and_strips_prefix():
    workouts, _ = parse_apple_export(FIXTURE, user_key="khash")
    assert len(workouts) == 2
    types = {w.activity_type for w in workouts}
    assert types == {"TraditionalStrengthTraining", "Yoga"}


def test_full_workout_stats_and_metadata():
    workouts, _ = parse_apple_export(FIXTURE, user_key="khash")
    w = next(w for w in workouts if w.activity_type == "TraditionalStrengthTraining")
    assert w.duration_min == 68.0
    assert w.active_energy_cal == 408.38
    assert w.basal_energy_cal == 154.7
    assert w.avg_heart_rate == 118.2
    assert w.max_heart_rate == 160.0
    assert w.distance_km == 4.82
    assert w.step_count == 320
    assert w.flights_climbed == 3
    assert w.indoor is True
    assert w.avg_mets == 6.5
    assert w.temperature_f == 73.4
    assert w.humidity_pct == 4300.0
    assert w.timezone == "America/Toronto"
    assert w.elevation_ascended_m == 86.52  # 8652 cm
    assert w.route_gpx_path == "/workout-routes/route_2026-06-12_7.26am.gpx"
    assert w.start_time.utcoffset() is not None


def test_minimal_workout_has_none_stats():
    workouts, _ = parse_apple_export(FIXTURE, user_key="khash")
    y = next(w for w in workouts if w.activity_type == "Yoga")
    assert y.active_energy_cal is None
    assert y.avg_heart_rate is None
    assert y.indoor is None
    assert y.route_gpx_path is None


def test_parses_daily_activity_and_ignores_records():
    _, days = parse_apple_export(FIXTURE, user_key="khash")
    assert len(days) == 2  # the <Record> is ignored
    d = next(d for d in days if d.date.isoformat() == "2026-06-12")
    assert d.active_energy_cal == 577.8
    assert d.active_energy_goal == 780.0
    assert d.exercise_minutes == 55
    assert d.exercise_goal == 60
    assert d.stand_hours == 7
    assert d.stand_goal == 12
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd server && uv run pytest tests/test_apple_parser.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'pulse_server.activity.apple_parser'`.

- [ ] **Step 4: Implement the parser**

Create `server/src/pulse_server/activity/apple_parser.py`:

```python
"""Stream an Apple Health ``export.xml`` into workout and daily-activity value
types. Uses ``iterparse`` and clears each element so the 1.4 GB file never
loads whole. Raw ``<Record>`` samples are skipped."""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from pathlib import Path
from xml.etree.ElementTree import Element, iterparse

from pulse_server.activity.models import AppleWorkout, DailyActivity

_APPLE_TIME_FORMAT = "%Y-%m-%d %H:%M:%S %z"
_WORKOUT_PREFIX = "HKWorkoutActivityType"
_QUANTITY_PREFIX = "HKQuantityTypeIdentifier"


def _parse_apple_time(value: str) -> DateTimeValue:
    """Parse an Apple timestamp with explicit offset.

    **Inputs:**
    - value (str): e.g. ``"2026-06-12 07:26:00 -0400"``.

    **Outputs:**
    - datetime: Timezone-aware datetime.
    """
    return DateTimeValue.strptime(value, _APPLE_TIME_FORMAT)


def _leading_number(value: str | None) -> float | None:
    """Extract the leading numeric token from a metadata value.

    Apple metadata values look like ``"73.4 degF"`` or ``"8652 cm"``; this
    returns the number, or None when absent/non-numeric.

    **Inputs:**
    - value (str | None): Raw metadata value.

    **Outputs:**
    - float | None: Leading number, or None.
    """
    if not value:
        return None
    token = value.strip().split(" ", 1)[0]
    try:
        return float(token)
    except ValueError:
        return None


def _build_workout(elem: Element, user_key: str) -> AppleWorkout:
    """Build an ``AppleWorkout`` from a parsed ``<Workout>`` element.

    **Inputs:**
    - elem (Element): The ``<Workout>`` element with its children.
    - user_key (str): Owning user key.

    **Outputs:**
    - AppleWorkout: Populated value type (missing stats become None).
    """
    metadata = {
        m.get("key"): m.get("value") for m in elem.findall("MetadataEntry")
    }
    stats: dict[str, Element] = {
        (s.get("type") or "").removeprefix(_QUANTITY_PREFIX): s
        for s in elem.findall("WorkoutStatistics")
    }

    def stat_sum(name: str) -> float | None:
        s = stats.get(name)
        return float(s.get("sum")) if s is not None and s.get("sum") else None

    distance = stat_sum("DistanceWalkingRunning")
    if distance is None:
        distance = stat_sum("DistanceCycling")

    heart = stats.get("HeartRate")
    avg_hr = float(heart.get("average")) if heart is not None and heart.get("average") else None
    max_hr = float(heart.get("maximum")) if heart is not None and heart.get("maximum") else None

    steps = stat_sum("StepCount")
    flights = stat_sum("FlightsClimbed")

    indoor_raw = metadata.get("HKIndoorWorkout")
    indoor = (indoor_raw == "1") if indoor_raw is not None else None

    elevation_cm = _leading_number(metadata.get("HKElevationAscended"))
    elevation_m = elevation_cm / 100.0 if elevation_cm is not None else None

    route_ref = elem.find("WorkoutRoute/FileReference")
    route_path = route_ref.get("path") if route_ref is not None else None

    duration_raw = elem.get("duration")

    return AppleWorkout(
        user_key=user_key,
        activity_type=(elem.get("workoutActivityType") or "").removeprefix(_WORKOUT_PREFIX),
        source_name=elem.get("sourceName"),
        start_time=_parse_apple_time(elem.get("startDate")),
        end_time=_parse_apple_time(elem.get("endDate")),
        duration_min=float(duration_raw) if duration_raw else None,
        active_energy_cal=stat_sum("ActiveEnergyBurned"),
        basal_energy_cal=stat_sum("BasalEnergyBurned"),
        avg_heart_rate=avg_hr,
        max_heart_rate=max_hr,
        distance_km=distance,
        step_count=int(steps) if steps is not None else None,
        flights_climbed=int(flights) if flights is not None else None,
        indoor=indoor,
        elevation_ascended_m=elevation_m,
        avg_mets=_leading_number(metadata.get("HKAverageMETs")),
        temperature_f=_leading_number(metadata.get("HKWeatherTemperature")),
        humidity_pct=_leading_number(metadata.get("HKWeatherHumidity")),
        timezone=metadata.get("HKTimeZone"),
        route_gpx_path=route_path,
    )


def _build_daily(elem: Element, user_key: str) -> DailyActivity:
    """Build a ``DailyActivity`` from an ``<ActivitySummary>`` element.

    **Inputs:**
    - elem (Element): The ``<ActivitySummary>`` element.
    - user_key (str): Owning user key.

    **Outputs:**
    - DailyActivity: Populated value type.
    """
    return DailyActivity(
        user_key=user_key,
        date=DateValue.fromisoformat(elem.get("dateComponents")),
        active_energy_cal=float(elem.get("activeEnergyBurned")),
        active_energy_goal=float(elem.get("activeEnergyBurnedGoal")),
        exercise_minutes=int(float(elem.get("appleExerciseTime"))),
        exercise_goal=int(float(elem.get("appleExerciseTimeGoal"))),
        stand_hours=int(float(elem.get("appleStandHours"))),
        stand_goal=int(float(elem.get("appleStandHoursGoal"))),
    )


def parse_apple_export(
    path: str | Path, *, user_key: str
) -> tuple[list[AppleWorkout], list[DailyActivity]]:
    """Stream an Apple Health export into workouts and daily activity.

    **Inputs:**
    - path (str | Path): Path to ``export.xml``.
    - user_key (str): Owning user key applied to every row.

    **Outputs:**
    - tuple[list[AppleWorkout], list[DailyActivity]]: All workout sessions and
      daily activity summaries; raw samples are ignored.
    """
    workouts: list[AppleWorkout] = []
    days: list[DailyActivity] = []

    for event, elem in iterparse(str(path), events=("end",)):
        if elem.tag == "Workout":
            workouts.append(_build_workout(elem, user_key))
            elem.clear()
        elif elem.tag == "ActivitySummary":
            days.append(_build_daily(elem, user_key))
            elem.clear()
        elif elem.tag == "Record":
            elem.clear()

    return workouts, days
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd server && uv run pytest tests/test_apple_parser.py -v`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add server/src/pulse_server/activity/apple_parser.py server/tests/test_apple_parser.py server/tests/fixtures/activity/apple_sample.xml
git commit -m "feat(server): streaming Apple Health export parser"
```

---

### Task 5: Upsert repository

**Files:**
- Create: `server/src/pulse_server/activity/repository.py`
- Test: `server/tests/integration/test_activity_repository.py`

**Interfaces:**
- Consumes: all four dataclasses; the `ids.*` helpers; tables `apple_workouts`, `strength_workouts`, `strength_sets`, `daily_activity`.
- Produces (all async, each returns `(inserted, updated)` tuple of ints):
  - `upsert_apple_workouts(session, workouts: list[AppleWorkout]) -> tuple[int, int]`
  - `upsert_daily_activity(session, days: list[DailyActivity]) -> tuple[int, int]`
  - `upsert_strength(session, workouts: list[StrengthWorkout], sets: list[StrengthSet]) -> tuple[int, int]`

> Inserted-vs-updated is detected per row via the Postgres `xmax = 0` trick in a `RETURNING` clause (`xmax = 0` ⇒ freshly inserted). Volumes are small (~8k rows total for a one-off script), so per-row upserts are acceptable and give exact counts.

- [ ] **Step 1: Write the failing test**

Create `server/tests/integration/test_activity_repository.py`:

```python
"""Integration tests for activity upserts (idempotency + counts)."""

from __future__ import annotations

import os
from datetime import datetime, timezone

import pytest
import pytest_asyncio
from sqlalchemy import func, select

from pulse_server import db
from pulse_server.activity.models import (
    AppleWorkout,
    DailyActivity,
    StrengthSet,
    StrengthWorkout,
)
from pulse_server.activity import repository
from pulse_server.repositories.tables import (
    apple_workouts,
    daily_activity,
    strength_sets,
    strength_workouts,
)

pytestmark = pytest.mark.integration

TEST_DB_URL = os.environ.get("TEST_DATABASE_URL")


@pytest_asyncio.fixture
async def session():
    if TEST_DB_URL is None:
        pytest.skip("TEST_DATABASE_URL not set")
    await db.init_pool(TEST_DB_URL)
    async with db.get_session() as s:
        await s.execute(strength_sets.delete())
        await s.execute(strength_workouts.delete())
        await s.execute(apple_workouts.delete())
        await s.execute(daily_activity.delete())
        await s.commit()
        yield s
    await db.close_pool()


def _workout(activity="Yoga"):
    t = datetime(2026, 6, 13, 18, 0, tzinfo=timezone.utc)
    return AppleWorkout(
        user_key="khash", activity_type=activity, source_name="Watch",
        start_time=t, end_time=t, duration_min=30.0, active_energy_cal=None,
        basal_energy_cal=None, avg_heart_rate=None, max_heart_rate=None,
        distance_km=None, step_count=None, flights_climbed=None, indoor=None,
        elevation_ascended_m=None, avg_mets=None, temperature_f=None,
        humidity_pct=None, timezone=None, route_gpx_path=None,
    )


@pytest.mark.asyncio
async def test_apple_upsert_is_idempotent(session):
    inserted, updated = await repository.upsert_apple_workouts(session, [_workout()])
    await session.commit()
    assert (inserted, updated) == (1, 0)

    inserted2, updated2 = await repository.upsert_apple_workouts(session, [_workout()])
    await session.commit()
    assert (inserted2, updated2) == (0, 1)

    count = await session.scalar(select(func.count()).select_from(apple_workouts))
    assert count == 1


@pytest.mark.asyncio
async def test_strength_upsert_links_sets_to_workout(session):
    t = datetime(2026, 6, 12, 7, 26, tzinfo=timezone.utc)
    w = StrengthWorkout(user_key="khash", title="Chest Day", start_time=t, end_time=t, description=None)
    s = StrengthSet(
        user_key="khash", workout_title="Chest Day", workout_start_time=t,
        exercise_title="Incline Dumbbell Press", superset_id=None,
        exercise_notes=None, set_index=0, set_type="normal", weight_lbs=65.0,
        reps=12, distance_km=None, duration_seconds=None, rpe=8.0,
    )
    inserted, _ = await repository.upsert_strength(session, [w], [s])
    await session.commit()
    assert inserted == 2  # 1 workout + 1 set

    joined = await session.scalar(
        select(func.count())
        .select_from(strength_sets.join(strength_workouts))
    )
    assert joined == 1


@pytest.mark.asyncio
async def test_daily_upsert_is_idempotent(session):
    from datetime import date
    day = DailyActivity(
        user_key="khash", date=date(2026, 6, 12), active_energy_cal=577.8,
        active_energy_goal=780.0, exercise_minutes=55, exercise_goal=60,
        stand_hours=7, stand_goal=12,
    )
    assert (await repository.upsert_daily_activity(session, [day]))[0] == 1
    await session.commit()
    assert (await repository.upsert_daily_activity(session, [day])) == (0, 1)
    await session.commit()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && TEST_DATABASE_URL=postgresql://localhost/pulse_test uv run pytest tests/integration/test_activity_repository.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'pulse_server.activity.repository'`.
(If no test DB is available, the fixture skips — still confirm the import error is what blocks it by running collection.)

- [ ] **Step 3: Implement the repository**

Create `server/src/pulse_server/activity/repository.py`:

```python
"""Idempotent upserts for activity rows. Each function returns
``(inserted, updated)``; insert-vs-update is detected per row with the
Postgres ``xmax = 0`` trick in a RETURNING clause."""

from __future__ import annotations

from sqlalchemy import text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from pulse_server.activity import ids
from pulse_server.activity.models import (
    AppleWorkout,
    DailyActivity,
    StrengthSet,
    StrengthWorkout,
)
from pulse_server.repositories.tables import (
    apple_workouts,
    daily_activity,
    strength_sets,
    strength_workouts,
)

_INSERTED_FLAG = text("(xmax = 0) AS inserted")


async def _upsert_row(session: AsyncSession, table, values: dict, conflict_cols: list[str]) -> bool:
    """Upsert one row and report whether it was freshly inserted.

    **Inputs:**
    - session (AsyncSession): Active session (caller owns the commit).
    - table: Target SQLAlchemy Core table.
    - values (dict): Column→value mapping for the row.
    - conflict_cols (list[str]): Columns forming the conflict target.

    **Outputs:**
    - bool: True if inserted, False if an existing row was updated.
    """
    stmt = pg_insert(table).values(**values)
    update_cols = {c: stmt.excluded[c] for c in values if c not in conflict_cols}
    stmt = stmt.on_conflict_do_update(
        index_elements=conflict_cols, set_=update_cols
    ).returning(_INSERTED_FLAG)
    result = await session.execute(stmt)
    return bool(result.scalar_one())


def _tally(flags: list[bool]) -> tuple[int, int]:
    """Split insert flags into (inserted, updated) counts.

    **Inputs:**
    - flags (list[bool]): Per-row inserted flags.

    **Outputs:**
    - tuple[int, int]: (inserted_count, updated_count).
    """
    inserted = sum(1 for f in flags if f)
    return inserted, len(flags) - inserted


async def upsert_apple_workouts(
    session: AsyncSession, workouts: list[AppleWorkout]
) -> tuple[int, int]:
    """Upsert Apple workout sessions keyed on their deterministic id.

    **Inputs:**
    - session (AsyncSession): Active session (caller commits).
    - workouts (list[AppleWorkout]): Parsed sessions.

    **Outputs:**
    - tuple[int, int]: (inserted, updated).
    """
    flags: list[bool] = []
    for w in workouts:
        values = {
            "id": ids.apple_workout_id(w.user_key, w.start_time, w.activity_type),
            "user_key": w.user_key,
            "activity_type": w.activity_type,
            "source_name": w.source_name,
            "start_time": w.start_time,
            "end_time": w.end_time,
            "duration_min": w.duration_min,
            "active_energy_cal": w.active_energy_cal,
            "basal_energy_cal": w.basal_energy_cal,
            "avg_heart_rate": w.avg_heart_rate,
            "max_heart_rate": w.max_heart_rate,
            "distance_km": w.distance_km,
            "step_count": w.step_count,
            "flights_climbed": w.flights_climbed,
            "indoor": w.indoor,
            "elevation_ascended_m": w.elevation_ascended_m,
            "avg_mets": w.avg_mets,
            "temperature_f": w.temperature_f,
            "humidity_pct": w.humidity_pct,
            "timezone": w.timezone,
            "route_gpx_path": w.route_gpx_path,
        }
        flags.append(await _upsert_row(session, apple_workouts, values, ["id"]))
    return _tally(flags)


async def upsert_daily_activity(
    session: AsyncSession, days: list[DailyActivity]
) -> tuple[int, int]:
    """Upsert daily activity summaries keyed on (user_key, date).

    **Inputs:**
    - session (AsyncSession): Active session (caller commits).
    - days (list[DailyActivity]): Parsed daily summaries.

    **Outputs:**
    - tuple[int, int]: (inserted, updated).
    """
    flags: list[bool] = []
    for d in days:
        values = {
            "user_key": d.user_key,
            "date": d.date,
            "active_energy_cal": d.active_energy_cal,
            "active_energy_goal": d.active_energy_goal,
            "exercise_minutes": d.exercise_minutes,
            "exercise_goal": d.exercise_goal,
            "stand_hours": d.stand_hours,
            "stand_goal": d.stand_goal,
        }
        flags.append(await _upsert_row(session, daily_activity, values, ["user_key", "date"]))
    return _tally(flags)


async def upsert_strength(
    session: AsyncSession,
    workouts: list[StrengthWorkout],
    sets: list[StrengthSet],
) -> tuple[int, int]:
    """Upsert Hevy session headers and their sets keyed on deterministic ids.

    **Inputs:**
    - session (AsyncSession): Active session (caller commits).
    - workouts (list[StrengthWorkout]): Deduplicated session headers.
    - sets (list[StrengthSet]): Flat list of sets.

    **Outputs:**
    - tuple[int, int]: (inserted, updated) across both tables combined.
    """
    flags: list[bool] = []
    for w in workouts:
        values = {
            "id": ids.strength_workout_id(w.user_key, w.title, w.start_time),
            "user_key": w.user_key,
            "title": w.title,
            "start_time": w.start_time,
            "end_time": w.end_time,
            "description": w.description,
        }
        flags.append(await _upsert_row(session, strength_workouts, values, ["id"]))
    for s in sets:
        workout_id = ids.strength_workout_id(s.user_key, s.workout_title, s.workout_start_time)
        values = {
            "id": ids.strength_set_id(workout_id, s.exercise_title, s.set_index),
            "strength_workout_id": workout_id,
            "user_key": s.user_key,
            "exercise_title": s.exercise_title,
            "superset_id": s.superset_id,
            "exercise_notes": s.exercise_notes,
            "set_index": s.set_index,
            "set_type": s.set_type,
            "weight_lbs": s.weight_lbs,
            "reps": s.reps,
            "distance_km": s.distance_km,
            "duration_seconds": s.duration_seconds,
            "rpe": s.rpe,
        }
        flags.append(await _upsert_row(session, strength_sets, values, ["id"]))
    return _tally(flags)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && TEST_DATABASE_URL=postgresql://localhost/pulse_test uv run pytest tests/integration/test_activity_repository.py -v`
Expected: PASS (3 tests). The session fixture bootstraps schema via the integration conftest, so the new tables exist.

- [ ] **Step 5: Commit**

```bash
git add server/src/pulse_server/activity/repository.py server/tests/integration/test_activity_repository.py
git commit -m "feat(server): idempotent activity upsert repository"
```

---

### Task 6: Import CLI script + end-to-end test

**Files:**
- Create: `server/src/pulse_server/scripts/__init__.py`
- Create: `server/src/pulse_server/scripts/import_health_data.py`
- Test: `server/tests/integration/test_import_health_data.py`

**Interfaces:**
- Consumes: `parse_apple_export`, `parse_hevy_csv`, all `repository.upsert_*`, `db.init_pool/get_session/transaction/close_pool`, `get_settings`.
- Produces: `async def run_import(apple_path: str | None, hevy_path: str | None, user_key: str) -> dict[str, tuple[int, int]]` returning per-source `(inserted, updated)`; `main(argv: list[str] | None = None) -> int` argparse entrypoint.

- [ ] **Step 1: Write the failing test**

Create `server/tests/integration/test_import_health_data.py`:

```python
"""End-to-end test of the import script over the parser fixtures."""

from __future__ import annotations

import os
from pathlib import Path

import pytest
import pytest_asyncio
from sqlalchemy import func, select

from pulse_server import db
from pulse_server.repositories.tables import (
    apple_workouts,
    daily_activity,
    strength_sets,
    strength_workouts,
)
from pulse_server.scripts.import_health_data import run_import

pytestmark = pytest.mark.integration

TEST_DB_URL = os.environ.get("TEST_DATABASE_URL")
FIXTURES = Path(__file__).parents[1] / "fixtures" / "activity"


@pytest_asyncio.fixture(autouse=True)
async def _clean():
    if TEST_DB_URL is None:
        pytest.skip("TEST_DATABASE_URL not set")
    await db.init_pool(TEST_DB_URL)
    async with db.get_session() as s:
        await s.execute(strength_sets.delete())
        await s.execute(strength_workouts.delete())
        await s.execute(apple_workouts.delete())
        await s.execute(daily_activity.delete())
        await s.commit()
    await db.close_pool()
    yield


@pytest.mark.asyncio
async def test_run_import_populates_all_tables():
    summary = await run_import(
        apple_path=str(FIXTURES / "apple_sample.xml"),
        hevy_path=str(FIXTURES / "hevy_sample.csv"),
        user_key="khash",
    )
    assert summary["apple_workouts"] == (2, 0)
    assert summary["daily_activity"] == (2, 0)
    assert summary["strength"][0] == 5  # 2 workouts + 3 sets inserted

    await db.init_pool(TEST_DB_URL)
    async with db.get_session() as s:
        assert await s.scalar(select(func.count()).select_from(apple_workouts)) == 2
        assert await s.scalar(select(func.count()).select_from(strength_sets)) == 3
        assert await s.scalar(select(func.count()).select_from(daily_activity)) == 2
    await db.close_pool()


@pytest.mark.asyncio
async def test_run_import_is_idempotent():
    args = dict(
        apple_path=str(FIXTURES / "apple_sample.xml"),
        hevy_path=str(FIXTURES / "hevy_sample.csv"),
        user_key="khash",
    )
    await run_import(**args)
    summary = await run_import(**args)
    assert summary["apple_workouts"] == (0, 2)
    assert summary["strength"][0] == 0  # nothing newly inserted on re-run
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && TEST_DATABASE_URL=postgresql://localhost/pulse_test uv run pytest tests/integration/test_import_health_data.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'pulse_server.scripts.import_health_data'`.

- [ ] **Step 3: Implement the script**

Create `server/src/pulse_server/scripts/__init__.py`:

```python
"""Operational scripts run via ``python -m pulse_server.scripts.*``."""
```

Create `server/src/pulse_server/scripts/import_health_data.py`:

```python
"""Import Apple Health + Hevy exports into Postgres.

Usage:
    uv run python -m pulse_server.scripts.import_health_data \\
        --apple /path/to/export.xml --hevy "/path/to/workout.csv" [--user-key khash]
"""

from __future__ import annotations

import argparse
import asyncio
from zoneinfo import ZoneInfo

from pulse_server import db
from pulse_server.activity import repository
from pulse_server.activity.apple_parser import parse_apple_export
from pulse_server.activity.hevy_parser import parse_hevy_csv
from pulse_server.config import get_settings


async def run_import(
    apple_path: str | None, hevy_path: str | None, user_key: str
) -> dict[str, tuple[int, int]]:
    """Parse the given export files and upsert them, returning per-source counts.

    **Inputs:**
    - apple_path (str | None): Path to Apple ``export.xml``, or None to skip.
    - hevy_path (str | None): Path to the Hevy CSV, or None to skip.
    - user_key (str): Owning user key applied to every row.

    **Outputs:**
    - dict[str, tuple[int, int]]: Keys ``apple_workouts``, ``daily_activity``,
      ``strength`` → ``(inserted, updated)``. Skipped sources report ``(0, 0)``.

    **Raises/Throws:**
    - sqlalchemy.exc.SQLAlchemyError: On DB connectivity or statement failure.
    """
    settings = get_settings()
    tz = ZoneInfo(settings.timezone)

    summary: dict[str, tuple[int, int]] = {
        "apple_workouts": (0, 0),
        "daily_activity": (0, 0),
        "strength": (0, 0),
    }

    await db.init_pool(settings.database_url)
    try:
        async with db.get_session() as session, db.transaction(session):
            if apple_path:
                workouts, days = parse_apple_export(apple_path, user_key=user_key)
                summary["apple_workouts"] = await repository.upsert_apple_workouts(session, workouts)
                summary["daily_activity"] = await repository.upsert_daily_activity(session, days)
            if hevy_path:
                s_workouts, s_sets = parse_hevy_csv(hevy_path, user_key=user_key, tz=tz)
                summary["strength"] = await repository.upsert_strength(session, s_workouts, s_sets)
    finally:
        await db.close_pool()

    return summary


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint: parse args, run the import, print a per-table summary.

    **Inputs:**
    - argv (list[str] | None): Argument vector for testing; defaults to sys.argv.

    **Outputs:**
    - int: Process exit code (0 on success).
    """
    parser = argparse.ArgumentParser(description="Import Apple Health + Hevy exports into Postgres.")
    parser.add_argument("--apple", dest="apple", default=None, help="Path to Apple Health export.xml")
    parser.add_argument("--hevy", dest="hevy", default=None, help="Path to the Hevy CSV export")
    parser.add_argument(
        "--user-key", dest="user_key", default=None,
        help="Owning user key (defaults to settings.legacy_user_key)",
    )
    args = parser.parse_args(argv)

    if not args.apple and not args.hevy:
        parser.error("provide at least one of --apple or --hevy")

    user_key = args.user_key or get_settings().legacy_user_key
    summary = asyncio.run(run_import(args.apple, args.hevy, user_key))

    for name, (inserted, updated) in summary.items():
        print(f"{name:16} inserted={inserted:>6} updated={updated:>6}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && TEST_DATABASE_URL=postgresql://localhost/pulse_test uv run pytest tests/integration/test_import_health_data.py -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full suite + lint**

Run: `cd server && uv run pytest tests/ -v` (unit tests pass; integration skip without a DB).
Run: `cd server && uv run ruff check src/pulse_server/activity src/pulse_server/scripts` (if ruff is the project linter; otherwise skip).
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add server/src/pulse_server/scripts/ server/tests/integration/test_import_health_data.py
git commit -m "feat(server): import_health_data CLI (Apple Health + Hevy -> Postgres)"
```

---

### Task 7: Documentation

**Files:**
- Modify: `CLAUDE.md` (root) — add the activity tables to the Server schema list and note the import script.

**Interfaces:** none (docs only).

- [ ] **Step 1: Update CLAUDE.md**

In the root `CLAUDE.md`, in the Server "DB lifecycle" Tables list, append `apple_workouts`, `strength_workouts`, `strength_sets`, `daily_activity`. In the Server feature-surface area, add one line under a new "Scripts" note:

```
- `scripts/import_health_data.py` — one-off importer: parses an Apple Health
  `export.xml` (streaming) and a Hevy CSV into `apple_workouts` /
  `daily_activity` / `strength_workouts` / `strength_sets`. Idempotent via
  deterministic UUID5 ids. Run: `uv run python -m pulse_server.scripts.import_health_data --apple <xml> --hevy <csv>`.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: note activity-import tables and import script in CLAUDE.md"
```

- [ ] **Step 3: Run the real import (manual, outside the plan's automated steps)**

Once merged, run against the actual files to land the data:

```bash
cd server && uv run python -m pulse_server.scripts.import_health_data \
  --apple /Users/khxsh/Downloads/apple_health_export/export.xml \
  --hevy  "/Users/khxsh/Downloads/workout_data (1).csv"
```

Expected: prints non-zero `inserted` counts (~1,564 apple_workouts; ~1,286 daily_activity; ~256 strength_workouts + ~5,205 strength_sets on first run). A second run prints those as `updated`.

---

## Self-Review

**Spec coverage:**
- 4 tables → Task 1. ✓
- Deterministic ids → Task 2. ✓
- Hevy parser (grouping, blank→None, tz) → Task 3. ✓
- Apple streaming parser (prefix strip, stats, metadata, cm→m, ignore Records) → Task 4. ✓
- Idempotent upserts (ON CONFLICT, inserted/updated counts) → Task 5. ✓
- CLI script (streaming, summary, settings-driven) → Task 6. ✓
- Body-mass ignored → never parsed (Task 4 only handles Workout/ActivitySummary/Record). ✓
- Linking deferred → `linked_strength_workout_id` column exists, left NULL. ✓
- lbs no conversion → Task 1 column + Task 3 passes through raw. ✓
- Docs → Task 7. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✓

**Type consistency:** `parse_apple_export`, `parse_hevy_csv`, `upsert_apple_workouts/daily_activity/strength`, `run_import` signatures match between their defining task and their consumers. `StrengthSet` carries `workout_title`/`workout_start_time` so the repo recomputes the same `strength_workout_id` used for the parent — FK integrity holds. ✓

## Open questions

None.
