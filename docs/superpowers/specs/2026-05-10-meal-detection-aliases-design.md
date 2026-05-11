# Meal & Food Detection Aliases

**Date:** 2026-05-10
**Status:** Design approved, plan pending.

## Problem

`resolve_food(name)` and `get_meal(name=...)` are exact-match on `normalize_name(name)` (lowercase + trim + collapse whitespace) against `food_memory.normalized_name` and `meals.normalized_name`. Any phrasing drift ("pb sandwich" vs "peanut butter sandwich", "the wrap" vs "Buffalo Chicken Wrap") misses memory and forces a USDA search or duplicate `remember_food` calls. Meal name resolution has the same gap when the LLM calls `get_meal(name=...)` directly instead of fuzzy-matching from `list_meals`.

## Goal

Let one canonical food-memory or meal row match multiple user phrasings, with the LLM driving alias creation when it notices name drift.

Out of scope: server-side fuzzy / similarity / Levenshtein matching. Aliases are strict exact-match alternates.

## Decisions

- **Entities in scope:** `food_memory` and `meals`. Custom-food aliases dropped — lookups never go through `custom_foods.normalized_name` directly; `food_memory` rows already act as alias indirection for custom foods.
- **Alias creation:** LLM-driven via explicit MCP tools. Workflow instructions tell the model when to call them.
- **Storage:** single `aliases text[]` column per entity (normalized form only, no display variant — canonical name is the display).
- **Collisions:** reject with error. The (canonical_name ∪ aliases) namespace is unique per user per entity type.

## Data model

Migration adds to both `food_memory` and `meals`:

```sql
alter table food_memory add column aliases text[] not null default '{}';
alter table meals add column aliases text[] not null default '{}';

create index idx_food_memory_aliases on food_memory using gin (aliases);
create index idx_meals_aliases on meals using gin (aliases);

alter table food_memory add constraint food_memory_alias_not_self
  check (not (normalized_name = any(aliases)));
-- same for meals
```

Row-local invariants enforced by the constraint above plus the service layer:

- An alias may not equal the row's own `normalized_name` (CHECK constraint).
- Aliases on a single row are distinct (service layer de-dups before write).

Cross-row uniqueness via `BEFORE INSERT OR UPDATE` trigger per table. Trigger checks, for each element of `NEW.aliases`:

1. No other row (same `user_key`, different `id`) has that value as its `normalized_name`.
2. No other row has that value in its `aliases` array (`aliases && NEW.aliases`).
3. Symmetrically, `NEW.normalized_name` must not appear in any other row's `aliases`.

On violation, the trigger raises with a message including the colliding row's canonical name so the service layer can wrap it in a `ToolError`.

Rationale for trigger vs unique index: Postgres unique indexes can't natively cover "scalar value OR any element of an array." A side table would allow a unique index but adds a join to every resolve query and contradicts the chosen single-column storage.

## Service & repository changes

**Lookup widening:**

- `FoodMemoryRepository.get_by_name`: `WHERE user_key = $1 AND (normalized_name = $2 OR $2 = ANY(aliases))`
- `MealsRepository.get_meal_by_name`: same pattern.
- Both use the GIN index on `aliases` for the `ANY` clause.

`resolve_food_by_name` (service) needs no logic change — the wider `WHERE` is transparent.

**Listing:** `MealsRepository.list_meals`, `FoodMemoryRepository.list_for_user` add `aliases` to the projected columns.

**Write methods (new):**

- `FoodMemoryRepository.add_alias(user_key, normalized_name, alias)` — normalizes `alias`, appends if absent via `aliases = array_append(aliases, $alias)` (only if `NOT (alias = ANY(aliases))`).
- `FoodMemoryRepository.remove_alias(user_key, normalized_name, alias)` — `aliases = array_remove(aliases, $alias)`.
- Same pair on `MealsRepository`, keyed by `meal_id` (uuid) rather than name.

**Service-layer pre-check** (cheap, single-user; trigger remains as correctness backstop): before the write, query for collision and raise `ToolError("alias 'X' is already used by '<existing name>'")` so the LLM gets an informative message rather than a generic trigger error.

**No-op cases (filtered at the service layer before SQL write; silent, not errors):**

- Adding an alias equal to the row's own `normalized_name` (would also violate the CHECK constraint if not filtered).
- Adding an alias already present on the row.
- Removing an alias not present on the row.

## MCP tool surface

New tools:

- `add_food_alias(name: str, alias: str) -> FoodMemoryEntry` — looks up the memory row by `normalize_name(name)`, appends `normalize_name(alias)` to its `aliases`, returns the updated row. Raises `ToolError` if no memory row, or on collision.
- `remove_food_alias(name: str, alias: str) -> FoodMemoryEntry`
- `add_meal_alias(meal_id: str, alias: str) -> MealResponse`
- `remove_meal_alias(meal_id: str, alias: str) -> MealResponse`

Modified tools (gain optional `aliases: list[str] = []` parameter):

- `remember_food` — normalizes and stores aliases on creation.
- `create_meal` — same.

Modified responses (include `aliases` field):

- `FoodMemoryEntry`, `MealSummary`, `MealResponse` — added `aliases: list[str]` (default `[]`).
- Returned by `list_remembered_foods`, `list_meals`, `get_meal`, `resolve_food` (when `type != "none"`).

## Workflow instruction update

Append to `WORKFLOW_INSTRUCTIONS` in `mcp/server.py`:

> **AUTO-ALIAS ON NAME DRIFT.** When the user refers to an existing memory entry or saved meal under a phrasing that didn't exact-match (you matched it from `list_meals` / `list_remembered_foods` context, not from `resolve_food` / `get_meal` returning it directly), call `add_meal_alias` or `add_food_alias` with the user's phrasing after logging. Skip if the phrasing is generic ("breakfast", "lunch", "the usual") or if the user explicitly disambiguated this turn. Skip if you're not confident the phrasing should always map to the same entity.

The "skip generic" clause is essential — without it, `lunch` gets aliased to whatever was logged today and pollutes future resolution.

## iOS impact

DTO change only — no UI work for this spec.

- `FoodMemoryEntry`, `MealSummary`, `MealResponse` in `diet-tracker-ios/DietTracker/Models/` gain `aliases: [String]`.
- Decode as `[String]` with a default of `[]` for forward compatibility with older server builds (use `decodeIfPresent` + `?? []`).
- `CodingKeys` maps the snake-case `aliases` JSON key (no rename needed; already matches).
- Out of scope: surfacing alias add/remove in the iOS UI.

## Error handling

- Collision: `ToolError("alias '<alias>' is already used by '<existing canonical name>'")` — surfaced from service-layer pre-check.
- Missing target (`add_food_alias` for an unknown `name`, `add_meal_alias` for an unknown `meal_id`): `ToolError("Food memory not found")` / `ToolError("Meal not found")`.
- Empty alias string after normalization: `ToolError("Alias must be non-empty after normalization")`.
- Trigger violation (race-condition fallback): wrapped as `ToolError("Alias collision")` with the trigger's message preserved.

## Tests

**Unit (mocked DB):**

- `resolve_food_by_name` returns the row when input matches an alias.
- `add_food_alias` / `add_meal_alias` append happy path.
- Service pre-check raises `ToolError` with colliding row's canonical name in the message.
- No-op cases: alias = own normalized_name, alias already present, removing absent alias.
- `remember_food(..., aliases=["pb", "pbs"])` persists both.

**Integration (Postgres, `TEST_DATABASE_URL`):**

- Trigger fires when an inserted row has an alias equal to another row's canonical name.
- Trigger fires on alias-vs-alias collision across rows.
- Migration backfills existing rows to `'{}'` without data loss.
- GIN-indexed lookup returns the row for an alias that isn't equal to the canonical name.

**MCP layer:**

- `add_food_alias` collision returns ToolError with the existing name in the message.
- `list_meals` includes `aliases` in the response.
- `resolve_food(alias)` for an aliased memory returns `type="memory_usda"` or `type="custom_food"` correctly.
- `get_meal(name=alias)` returns the meal.

## Unresolved questions

- None at time of writing.
