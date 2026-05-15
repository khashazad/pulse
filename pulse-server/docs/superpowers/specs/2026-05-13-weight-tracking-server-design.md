# Weight Tracking — Server

**Status:** Design
**Date:** 2026-05-13
**Companion spec:** `diet-tracker-ios/docs/superpowers/specs/2026-05-13-weight-tracking-ios-design.md`

## Goal

Add storage and read endpoints to support a new "Weight" tab on iOS: daily weight logging (one row per `(user_key, date)`, upsertable), an optional target weight on the existing target profile, and a per-day calorie-totals range endpoint that iOS uses as the input to its analytics. Server stays storage-only; all analytics math lives on the client.

## Scope

**In:**
- New `weight_entries` table.
- `target_weight_lb` column added to `daily_target_profile`.
- CRUD endpoints under `/weight*`.
- `GET /calories_daily?from&to` range aggregate over `food_entries`.
- Pydantic DTOs, router/service/repository layering matching existing patterns.

**Out:**
- Server-side regression / maintenance-kcal / ETA math (iOS computes).
- Target-history tracking — `daily_target_profile` stays single-row per user (`updated_at` only). A future spec covers history.
- MCP tools for weight logging. The new endpoints are reachable through the existing legacy `?user_key=khash` path, but no MCP tool definitions are added.
- Migration tooling — schema changes are `IF NOT EXISTS` / `ADD COLUMN IF NOT EXISTS`, idempotent under `bootstrap_schema()`.

## Non-goals

- No event log of target changes. Updating the target weight overwrites the column.
- No multi-entry-per-day. The `(user_key, log_date)` unique index enforces one weight per day; PUT upserts.
- No timezone storage. `log_date` is the date string the client sent; iOS sends the user's local date (matches `daily_logs` convention).

## Contract with iOS

- **Storage unit:** pounds, fixed `numeric(6,2)`. Client may submit either `lb` or `kg`; server normalizes on write and stores the submitted `source_unit` for display fidelity on edit.
- **Date semantics:** `log_date` is a calendar date (`YYYY-MM-DD`), local to the user, not a timestamp. One row per `(user_key, log_date)`.
- **Targets:** `GET /targets` and `PUT /targets` carry `target_weight_lb: number | null` alongside the existing macro fields. Null means unset.
- **Range cap:** `/weight?from&to` and `/calories_daily?from&to` reject ranges spanning more than 366 days.

## Schema additions

Appended to `schema.sql`:

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

`weight_lb` precision `(6,2)` accommodates 9999.99 lb (well past any realistic value) with 0.01 lb resolution (~4.5 g — below scale uncertainty).

## Endpoints

All `/weight*` endpoints require an authenticated session (existing `require_session` dependency) and scope by `request.state.user_key`.

### `GET /weight?from=YYYY-MM-DD&to=YYYY-MM-DD`

- 200 → `WeightEntryResponse[]` ordered by `log_date asc`.
- 400 if `from > to` or `(to - from).days > 366` or either date unparseable.

### `GET /weight/{date}`

- 200 → `WeightEntryResponse`.
- 404 when no entry exists for that `(user_key, date)`.

### `PUT /weight/{date}`

Body: `{ "weight": number, "unit": "lb" | "kg" }`.

Behavior:
- Validate `weight > 0`, `unit ∈ {lb, kg}`, `date <= today`, `date >= today - 5 years`.
- Compute `weight_lb = round(weight, 2)` if `unit == "lb"`, else `round(weight * 2.20462262, 2)`.
- Upsert on `(user_key, log_date)`: insert or update `weight_lb`, `source_unit = unit`, `updated_at = now()`.

Returns:
- 200 → `WeightEntryResponse` (the resulting row).
- 400 on validation failure.

### `DELETE /weight/{date}`

- 204 on success.
- 404 if no row matches.

### `GET /calories_daily?from=YYYY-MM-DD&to=YYYY-MM-DD`

Aggregate over `food_entries` joined to `daily_logs`:

```sql
select daily_logs.log_date, sum(food_entries.calories)::integer as calories
  from food_entries
  join daily_logs on daily_logs.id = food_entries.daily_log_id
 where daily_logs.user_key = :user_key
   and daily_logs.log_date between :from and :to
 group by daily_logs.log_date
 order by daily_logs.log_date asc;
```

- 200 → `[{ "log_date": "YYYY-MM-DD", "calories": int }]`. Dates with zero entries are omitted (no row, not a zero-calorie row).
- 400 on the same range rules as `/weight`.

### Existing `GET /targets` and `PUT /targets`

- Response and request schemas gain `target_weight_lb: number | null`.
- `null` is returned when unset; `null` may be sent on PUT to clear.
- All other fields unchanged.

## DTOs

`models/weight.py`:

```python
class WeightEntryResponse(BaseModel):
    id: UUID
    log_date: date
    weight_lb: Decimal
    source_unit: Literal["lb", "kg"]
    created_at: datetime
    updated_at: datetime

class WeightEntryUpsert(BaseModel):
    weight: Decimal
    unit: Literal["lb", "kg"]

class CaloriesDailyRow(BaseModel):
    log_date: date
    calories: int
```

`models/targets.py` (extension of existing):
- Add `target_weight_lb: Decimal | None = None` to both response and PUT input models.

## Layering

- `routers/weight.py` — HTTP handlers, depends on `require_session` and `get_session_dependency`.
- `services/weight_service.py` — kg→lb conversion, upsert orchestration, range validation.
- `repositories/weight.py` — SQLAlchemy Core queries against `weight_entries`.
- `repositories/tables.py` — add `weight_entries` `Table` definition.
- `routers/summary.py` — add `GET /calories_daily` endpoint.
- `services/summary_service.py` — add `daily_calorie_totals(...)` returning `list[CaloriesDailyRow]`.
- `repositories/targets.py` — extend to read/write `target_weight_lb`.
- Router wiring in `app.py`.

## Validation and errors

| Condition | Status | Body |
|---|---|---|
| `weight <= 0` | 400 | `{"detail": "weight must be positive"}` |
| `unit ∉ {lb, kg}` | 400 | `{"detail": "unit must be 'lb' or 'kg'"}` |
| `date > today` | 400 | `{"detail": "cannot log weight in the future"}` |
| `date < today - 5y` | 400 | `{"detail": "date too far in past"}` |
| `from > to` | 400 | `{"detail": "from must be <= to"}` |
| `(to - from).days > 366` | 400 | `{"detail": "range cannot exceed 366 days"}` |
| `GET /weight/{date}` no row | 404 | `{"detail": "no weight entry for date"}` |
| `DELETE /weight/{date}` no row | 404 | `{"detail": "no weight entry for date"}` |

Unit conversion uses the exact constant `2.20462262` to match the iOS-side helper. Round half-to-even at scale 2.

## Testing

**Unit tests** (mock pool, `tests/`):

- `test_weight_routes.py`
  - PUT (lb) happy path, returns the upserted row.
  - PUT (kg) normalizes to lb with the expected rounding.
  - GET range happy path with ordering.
  - GET single happy path / 404.
  - DELETE 204 / 404.
  - All 400 conditions from the validation table.
- `test_weight_service.py`
  - kg→lb exact conversion at boundary values (e.g., 70 kg → 154.32 lb).
  - Upsert collision: PUT same date twice with different values produces one row with the second value and `updated_at` advanced.
  - `source_unit` retained per PUT (re-PUT in kg flips `source_unit` to `'kg'`).
- `test_calories_daily.py`
  - Sum aggregation across multiple entries on the same day.
  - Dates with no entries are omitted.
  - Range bounds enforced.
- `test_targets.py` (extend existing)
  - `target_weight_lb` round-trips, supports `null`.

**Integration tests** (`pytest.mark.integration`, real Postgres):

- `test_weight_integration.py`
  - PUT → GET single round-trip with kg input verifies stored lb.
  - PUT twice → GET single shows the second value.
  - PUT then DELETE then GET 404.
  - Range query over seeded dates returns ordered list.
  - `bootstrap_schema()` runs twice without error (idempotency).

## Out of scope, called out

- No MCP tools added in this spec. A follow-up can wrap `PUT /weight/{date}`, `GET /weight`, and `GET /targets` (for target weight) as MCP tools when wanted.
- No body composition (body fat %, muscle mass). Just one scalar `weight_lb`.
- No CSV import/export. Could be added later as a separate spec.

## Open questions

None at design time. Defaults locked: pound storage, 366-day range cap, 5-year past cap, single-row targets.
