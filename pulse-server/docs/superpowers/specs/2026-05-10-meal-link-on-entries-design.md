# Meal Link on Food Entries — Server

**Status:** Design
**Date:** 2026-05-10
**Companion spec:** `diet-tracker-ios/docs/superpowers/specs/2026-05-10-collapsible-meal-rows-design.md`

## Goal

Stamp every `food_entries` row created by `log_meal` with the originating meal's id and a denormalized snapshot of the meal's name. This gives clients enough information to render meal-sourced entries as a single collapsible row labelled with the meal name, and to recognize when the same meal has been logged multiple times in a day.

## Scope

In:
- New nullable `meal_id` (FK → `meals.id`, `ON DELETE SET NULL`) and `meal_name` (text) columns on `food_entries`.
- `services/meals_service.log_meal` populates both fields on the entries it creates.
- API responses (`FoodEntryRead`, daily summary entries, MCP entry shapes) include the new fields.
- Alembic migration + idempotent `schema.sql` mirror.

Out:
- Backfilling pre-existing rows. `meal_id` and `meal_name` stay NULL on historical entries; clients render them as anonymous meal groups.
- Manual multi-item entry batches that don't go through `log_meal`. They still share an `entry_group_id` but won't have `meal_id`/`meal_name`. Same anonymous-group rendering on the client.
- Mutating `meal_name` on historical entries when a meal is renamed. The denormalized name is frozen at log time.
- Any change to the `meals` or `meal_items` tables.

## Non-goals

- Not adding a `meal_logs` aggregate table. Repeat detection is "same `meal_id` on multiple `entry_group_id` buckets within a day" — computed client-side from the existing `/days/{date}` payload.
- Not breaking `entry_group_id`'s contract. It still uniquely identifies a single batched-insert. `meal_id` is a separate, optional dimension.
- Not enforcing that all entries within a single `entry_group_id` share the same `meal_id`. They will in practice (set together by `log_meal`), but no DB constraint codifies it.

## Schema

Two columns added to `food_entries`:

| col | type | nullable | notes |
|---|---|---|---|
| `meal_id` | `uuid` | yes | FK → `meals.id` `ON DELETE SET NULL` |
| `meal_name` | `text` | yes | denormalized at log time; never updated |

Plus index `idx_food_entries_meal_id (meal_id)` to support potential future "log instances of meal X" queries; cheap and small.

Existing `entry_group_id` and all other columns unchanged.

### Constraints

- No `CHECK` enforcing `meal_id IS NOT NULL ↔ meal_name IS NOT NULL`. They will move together in practice (both set by `log_meal`, both NULL otherwise), but the FK's `ON DELETE SET NULL` only nulls `meal_id`, leaving `meal_name` populated — which is exactly the desired behavior (client still gets the historical name after the template is deleted). A CHECK would block that.
- `ON DELETE SET NULL`, not `CASCADE`. Deleting a saved meal must not delete historical food entries.

## Migration

`alembic/versions/<rev>_add_meal_link_to_food_entries.py`:

```python
def upgrade():
    op.add_column("food_entries", sa.Column("meal_id", UUID(as_uuid=True), nullable=True))
    op.add_column("food_entries", sa.Column("meal_name", sa.Text(), nullable=True))
    op.create_foreign_key(
        "fk_food_entries_meal_id",
        "food_entries", "meals",
        ["meal_id"], ["id"],
        ondelete="SET NULL",
    )
    op.create_index("idx_food_entries_meal_id", "food_entries", ["meal_id"])

def downgrade():
    op.drop_index("idx_food_entries_meal_id", table_name="food_entries")
    op.drop_constraint("fk_food_entries_meal_id", "food_entries", type_="foreignkey")
    op.drop_column("food_entries", "meal_name")
    op.drop_column("food_entries", "meal_id")
```

`schema.sql` mirrors the same additions guarded by `IF NOT EXISTS` (matches existing bootstrap pattern). Both Alembic and `schema.sql` paths must converge on the same final shape — `bootstrap_schema()` runs `schema.sql` on every startup, so any drift would be visible immediately.

`repositories/tables.py` adds the two `Column` definitions and the `Index` to the existing `food_entries` `Table` so SQLAlchemy expressions can SELECT them.

## Code changes

### `services/meals_service.log_meal`

Currently builds a list of `FoodEntryCreate` items from the meal's items and calls `create_entries_with_side_effects`. Add `meal_id=meal_id` and `meal_name=meal_row["name"]` to each constructed `FoodEntryCreate`. Capture `meal_row["name"]` at the time of expansion — if the meal is renamed mid-request (it can't be in single-user single-process today, but treat the value as a snapshot regardless).

### `models/entries.py`

`FoodEntryCreate` gains:

```python
meal_id: UUID | None = None
meal_name: str | None = None
```

`FoodEntryRead` (and any response model exposing entries to the client) gains the same two fields. JSON encoding is `meal_id` / `meal_name` (snake_case, like the rest of the schema).

### `repositories/entries.py`

- Insert path: include `meal_id` and `meal_name` in the columns/values when present (default to NULL).
- Select paths (single entry, by daily log, by date range): include the two new columns. Any `_row_to_dict` / response-shaping helper passes them through.

### `mcp/server.py`

Anywhere a food-entry shape is constructed for an MCP tool response, include the two new fields. Discoverable via the existing `entry_group_id` references already in the file.

## API surface

No new endpoints. The shape change is additive on existing payloads:

- `GET /days/{date}` — entries inside `entries: [...]` now optionally include `meal_id` and `meal_name`.
- `POST /entries` — manual entries return both as `null`.
- `POST /meals/{id}/log` — returned entries (and the resulting daily summary) carry both populated.
- `GET /entries/{id}`, `GET /entries?...` — both fields present, possibly null.

Old clients ignore unknown fields; the iOS decoder uses `Optional` types so missing-vs-null is moot.

## Auth and tenancy

No auth changes. `meal_id` is constrained by FK to a row in `meals`, which is itself scoped per `user_key` — and `log_meal` already requires the meal to belong to the requesting user. So a stamped `meal_id` will only ever reference a meal owned by the same `user_key` as the entry. No additional cross-user check needed.

## Tests

### Unit

- `log_meal` round-trip: created entries carry the originating `meal_id` and a `meal_name` matching `meals.name` at the time of the call.
- Direct entry creation via `/entries`: both fields default to NULL.
- Renaming a meal after `log_meal` does not change `meal_name` on historical entries.
- Deleting a meal after `log_meal` sets `meal_id` to NULL on historical entries but leaves `meal_name` populated.

### Integration

- `GET /days/{date}` after `log_meal` returns entries with `meal_id` and `meal_name` set.
- Existing daily-summary contract (totals, ordering) unchanged.

## Rollout

1. Migration runs (idempotent against fresh DBs and `schema.sql` bootstrap).
2. Server change ships. Old iOS clients ignore the new fields; no breakage.
3. iOS app (companion spec) ships separately. On first day-view load it sees the new fields and renders collapsed meal rows.

No coordinated cutover. Server is forward-compatible, client is backward-compatible.
