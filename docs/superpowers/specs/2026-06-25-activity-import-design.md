# Activity Import — Apple Health + Hevy → Postgres (Phase 1)

**Date:** 2026-06-25
**Scope:** Server-side ingestion + schema only. No UI, no server upload endpoint, no iOS changes.
**Status:** Approved design, pending implementation plan.

## Goal

Get the user's workout and daily-activity history out of two manual export files
and into the Pulse Postgres (Supabase) database, in a shape that a later UI phase
can read directly to show: workouts to browse, calories per day, and hours per
day spent working out.

Phase 1 deliberately stops at "data is in the database and re-importable." UI is
a separate later phase informed by what these tables hold.

## Data sources (verified against the real files)

### 1. Hevy strength export — `workout_data (1).csv` (610 KB, 5,205 rows)

One row **per set**. Columns:
`title, start_time, end_time, description, exercise_title, superset_id,
exercise_notes, set_index, set_type, weight_lbs, reps, distance_km,
duration_seconds, rpe`.

- `start_time` / `end_time` format: `"12 Jun 2026, 08:34"` (day-month-year, local).
- A *session* is identified by `(title, start_time)` — titles repeat weekly
  (256 distinct titles across the file), so title alone is not unique.
- `set_type` ∈ {`warmup`, `normal`, …}. `weight_lbs`, `reps`, `distance_km`,
  `duration_seconds`, `rpe` are frequently blank depending on exercise type.

### 2. Apple Health export — `export.xml` (1.4 GB)

Two relevant element kinds (everything else — millions of raw `Record`
samples for heart rate, steps, distance, basal energy, body mass — is **ignored**):

- **`<Workout>`** — 1,564 sessions, 2018→2026. Activity types: strength (623),
  Other (449), StairClimbing (156), Yoga (142), Cycling (94), Walking (61),
  Running (25), Hiking (7), Elliptical (5), HIIT (2). Attributes:
  `workoutActivityType, duration (min), startDate, endDate, sourceName`. Nested:
  - `<WorkoutStatistics type="…ActiveEnergyBurned" sum=… unit="Cal"/>` and the
    same for BasalEnergyBurned, HeartRate (avg/max via `average`/`maximum`
    when present, else `sum`), DistanceWalkingRunning/DistanceCycling (km),
    StepCount, FlightsClimbed.
  - `<MetadataEntry>` for `HKIndoorWorkout`, `HKAverageMETs`,
    `HKWeatherTemperature`, `HKWeatherHumidity`, `HKTimeZone`,
    `HKElevationAscended`.
  - `<WorkoutRoute><FileReference path="/workout-routes/…gpx"/>` (path only).
  - Workouts carry no reliable own UUID → identity is derived (see below).
- **`<ActivitySummary>`** — 1,286 daily rows. Attributes:
  `dateComponents (YYYY-MM-DD), activeEnergyBurned, activeEnergyBurnedGoal,
  appleExerciseTime, appleExerciseTimeGoal, appleStandHours, appleStandHoursGoal`.

### Source overlap (intentionally not resolved in phase 1)

Apple Health's 623 `TraditionalStrengthTraining` workouts are the **same
sessions** as the Hevy CSV, seen from a different angle (Hevy = exercise/set
detail; Apple = calories/HR/duration). Phase 1 stores both **side by side**.
`apple_workouts.linked_strength_workout_id` exists as a nullable column for a
future time-overlap matching pass; it is left NULL now.

## Schema — 4 new tables

Added to `server/schema.sql` (single source of truth, idempotent guarded DDL)
and mirrored by hand in `server/src/pulse_server/repositories/tables.py`
(SQLAlchemy Core `Table` objects). All tables scoped by `user_key`
(today: `LEGACY_USER_KEY`). Deterministic ids follow the existing
`log_ids.daily_log_id` UUID5 pattern so upserts are idempotent without a prior read.

### `apple_workouts`
One row per Apple Health `<Workout>` (≈1,564).

| column | type | notes |
|---|---|---|
| `id` | UUID PK | UUID5 of `f"{user_key}:{start_iso}:{activity_type}"` |
| `user_key` | text not null | |
| `activity_type` | text not null | `HKWorkoutActivityType` prefix stripped, e.g. `TraditionalStrengthTraining` |
| `source_name` | text | e.g. "Khashayar's Apple Watch" |
| `start_time` | timestamptz not null | |
| `end_time` | timestamptz not null | |
| `duration_min` | numeric | from `duration` attr |
| `active_energy_cal` | numeric null | WorkoutStatistics ActiveEnergyBurned sum |
| `basal_energy_cal` | numeric null | |
| `avg_heart_rate` | numeric null | HeartRate `average` |
| `max_heart_rate` | numeric null | HeartRate `maximum` |
| `distance_km` | numeric null | walking/running or cycling distance |
| `step_count` | integer null | |
| `flights_climbed` | integer null | |
| `indoor` | boolean null | `HKIndoorWorkout` |
| `elevation_ascended_m` | numeric null | `HKElevationAscended` (cm → m) |
| `avg_mets` | numeric null | `HKAverageMETs` |
| `temperature_f` | numeric null | `HKWeatherTemperature` (degF) |
| `humidity_pct` | numeric null | `HKWeatherHumidity` |
| `timezone` | text null | `HKTimeZone` |
| `route_gpx_path` | text null | FileReference path, reference only |
| `linked_strength_workout_id` | UUID null | future link, NULL in phase 1 |
| `created_at` | timestamptz not null default now() | |

Unique on `id` (PK). Index `(user_key, start_time)`.

### `strength_workouts`
Hevy session header. id = UUID5 of `f"{user_key}:{title}:{start_iso}"`.

`id` (UUID PK), `user_key` (text), `title` (text), `start_time` (timestamptz),
`end_time` (timestamptz), `description` (text null), `created_at`.
Index `(user_key, start_time)`.

### `strength_sets`
One row per Hevy set (≈5,205). id = UUID5 of
`f"{strength_workout_id}:{exercise_title}:{set_index}"`.

`id` (UUID PK), `strength_workout_id` (UUID not null, FK → `strength_workouts.id`
on delete cascade), `user_key` (text), `exercise_title` (text), `superset_id`
(text null), `exercise_notes` (text null), `set_index` (integer not null),
`set_type` (text), `weight_lbs` (numeric null — **kept in lbs, no conversion**),
`reps` (integer null), `distance_km` (numeric null), `duration_seconds`
(integer null), `rpe` (numeric null), `created_at`.
Index `(strength_workout_id)`.

### `daily_activity`
One row per Apple `<ActivitySummary>` (≈1,286). PK `(user_key, date)`.

`user_key` (text), `date` (date), `active_energy_cal` (numeric),
`active_energy_goal` (numeric), `exercise_minutes` (integer),
`exercise_goal` (integer), `stand_hours` (integer), `stand_goal` (integer),
`created_at`. Composite PK `(user_key, date)`.

## The import script

`server/src/pulse_server/scripts/import_health_data.py`, run from `server/`:

```bash
uv run python -m pulse_server.scripts.import_health_data \
  --apple /path/to/export.xml \
  --hevy  "/path/to/workout_data (1).csv" \
  [--user-key khash]   # defaults to settings.LEGACY_USER_KEY
```

Behavior:

- **Apple XML** is parsed with `xml.etree.ElementTree.iterparse` streaming over
  the 1.4 GB file. Only `<Workout>` and `<ActivitySummary>` end-events are
  handled; **`elem.clear()`** is called after each top-level element so memory
  stays flat. Raw `<Record>` samples are skipped without buffering.
- **Hevy CSV** is parsed with `csv.DictReader`. Rows are grouped into sessions by
  `(title, start_time)`; each group yields one `strength_workouts` upsert plus
  one `strength_sets` upsert per row.
- **Writes** reuse the server's DB config (`settings.DATABASE_URL`) and the
  SQLAlchemy Core `Table` objects. Each table is written with
  `insert(...).on_conflict_do_update(...)` (Postgres upsert) keyed on the PK,
  so re-running after a fresh export updates rows in place and never duplicates.
- Date parsing: Apple dates `YYYY-MM-DD HH:MM:SS ±ZZZZ` carry an explicit offset
  and are stored as-is. Hevy dates `"%d %b %Y, %H:%M"` carry no zone — they are
  interpreted in `settings.TIMEZONE` and then stored as timestamptz, so both
  sources land in the same absolute-time column type.
- Prints a per-table summary: rows inserted vs. updated, plus skip counts.
- A standalone async `main()` using the existing engine helper; not wired into
  the FastAPI app lifespan.

## What phase-2 UI reads (informational, not built now)

- **Calories per day** → `daily_activity.active_energy_cal`.
- **Hours per day working out** → `SUM(apple_workouts.duration_min)` grouped by
  `date(start_time)`.
- **Browse workouts** → `apple_workouts` rows, with `strength_sets` joined via a
  later link for the lifting breakdown.

## Out of scope (YAGNI for phase 1)

- Linking Apple ↔ Hevy sessions (column exists, populated later).
- Raw heart-rate / step / distance time-series ingestion.
- GPX route file parsing (only the path string is stored).
- Apple Health body-mass readings (202 of them) — **ignored**; Pulse's existing
  `weight_entries` remains the sole weight source.
- Any server HTTP upload endpoint, automation/cron, or Hevy API integration.
- All iOS / UI work.

## Decisions locked

1. Apple body-mass readings ignored — don't touch `weight_entries`.
2. Table names: `apple_workouts`, `strength_workouts`, `strength_sets`,
   `daily_activity` (no shared prefix).
3. Hevy weights stay in lbs, no conversion.

## Open questions

None outstanding.
