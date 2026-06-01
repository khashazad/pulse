---
name: pulse-diet-mcp
description: >-
  Log and manage nutrition data through the Pulse diet-tracking MCP server. Use
  whenever the user wants to log food or meals, check their daily macros or
  targets, or manage saved meals, custom foods, food memory, and meal-prep
  containers — including editing, deleting, or backdating past entries. Covers
  the canonical workflow: match saved meals first, resolve foods from memory
  before searching USDA, scale macros to the eaten quantity, and remember
  corrections. The single user eats consistently day to day, so resolve
  ambiguous food items against recent days' logs before asking them.
---

# Pulse Diet-Tracking MCP

The Pulse server exposes its nutrition domain as ~31 MCP tools (mounted at
`/mcp`). This is a **single-user** system — every tool operates on one person's
data (`user_key = "khash"`), so there is never a "which user?" question. Tool
names below are the bare names; in a client they appear under the configured
MCP server (named `diet`), e.g. `log_food`, `resolve_food`, `get_day`.

Use this skill any time the conversation is about what the user ate, their
macros/targets, or curating their saved meals, custom foods, food memory, or
meal-prep containers.

## Golden rules (read first)

1. **Macros are always pre-scaled.** Every `log_food` / `remember_food` /
   meal-item call takes the **final** calories/protein/carbs/fat for the
   quantity actually eaten. The tools do **not** scale for you. The one
   exception is `log_meal`, which replays a saved meal's items at their stored
   quantities — never scale a meal.
2. **Exactly one food source per entry/item:** either `fdc_id` +
   `usda_description` (USDA-backed) **or** `custom_food_id` (a saved custom
   food). Supplying both or neither is an error.
3. **`basis` tells you how to scale.** Foods carry `per_100g`, `per_serving`,
   or `per_unit`. Read the basis off `resolve_food` / `search_food`, scale to
   the user's quantity, then pass the result to `log_food`.
4. **The day bucket comes from `consumed_at`** (projected into server
   timezone). Omit it to stamp "now"; pass `YYYY-MM-DD` (expands to noon) or a
   full ISO-8601 timestamp to backdate/future-date. You cannot pass a calendar
   date directly.
5. **Resolve relative dates before calling.** Convert "yesterday",
   "Wednesday", "tomorrow" to an absolute `YYYY-MM-DD` yourself (today's date
   is in your context).

## Consistency-first disambiguation

**The user eats largely the same things day to day.** Treat their history as
the primary source of truth for anything ambiguous — *do not guess, and do not
jump straight to asking.* When a food mention is unclear (which food, which
variant/brand, what quantity, or which meal it belongs to), resolve it in this
order:

1. **Memory & saved meals first.** Call `resolve_food(name)` and consult
   `list_meals` / `list_remembered_foods`. A consistent eater usually already
   has the item remembered — that resolves the food *and* its macros.
2. **Then recent days' logs.** If memory doesn't settle it, call `get_day` for
   the **last few days** (e.g. yesterday and the day before) and look for the
   same item. Reuse the quantity, macros, and food source the user logged
   before. Example: "I had my usual oatmeal" with no amount → check what
   `oatmeal` was logged as recently and reuse that quantity.
3. **Only then ask.** If it's still genuinely ambiguous after checking memory
   and history — a new food, a real conflict between recent days, or a quantity
   you can't infer — ask the user a short, specific confirming question rather
   than logging a guess. Prefer "Same as yesterday — 60 g dry oats, ~220 kcal?"
   over an open-ended question; it's faster to confirm and respects the
   consistency assumption.

When you reuse a value from history, say so briefly ("logged the same 60 g oats
as yesterday") so the user can correct it if today was different.

## Canonical logging workflow

Follow this order on every food-related interaction (it mirrors the server's
own `WORKFLOW_INSTRUCTIONS`):

1. **Meals first.** Call `list_meals` once early. If anything the user says
   matches a saved meal name or alias — be liberal ("my breakfast", "the
   wrap") — call `log_meal(meal_id)` and stop. Meals log every ingredient at
   its original quantity; do not scale.
2. **Memory next.** For each individual food, call `resolve_food(name)` **before**
   searching USDA. If `type != "none"`, scale the returned per-basis macros to
   the user's quantity and `log_food`, passing `fdc_id` (for `memory_usda`
   hits) or `custom_food_id` (for `custom_food` hits). Skip `search_food`.
3. **USDA fallback.** Only when memory misses, call `search_food`, pick a
   candidate, scale its macros, and `log_food` with `fdc_id` +
   `usda_description`.
4. **Auto-remember on corrections.** If the user corrects your USDA pick
   (wrong food or wrong macros), after logging the corrected version call
   `remember_food` with the corrected `fdc_id`, `basis`, and **per-basis**
   macros so the next mention resolves directly. For photo/manual corrections
   with no USDA equivalent, use `save_custom_food` (it auto-remembers).
5. **Auto-alias on name drift.** When the user names an existing memory entry
   or meal under a phrasing that didn't exact-match (you matched it from
   `list_meals` / `list_remembered_foods` context, not from `resolve_food` /
   `get_meal` returning it directly), call `add_food_alias` / `add_meal_alias`
   with that phrasing after logging. Skip generic phrasings ("breakfast", "the
   usual") and cases where you're not confident the phrasing should always map
   to the same entity.
6. **Photo / manual macros.** When the user gives macros directly (photo or
   text) with no USDA reference, call `save_custom_food` with
   `basis="per_serving"` (the default for photo-derived foods) plus
   `serving_size` / `serving_size_unit` (e.g. `1` / `"wrap"`). Then `log_food`
   with the returned `custom_food_id`.
7. **Backdate / future-date.** Pass `consumed_at` to `log_food` / `log_meal`:
   `YYYY-MM-DD` for a date-only mention, a full ISO-8601 timestamp when the
   user gives an explicit time. Past, present, and future days are all allowed.
8. **Edit / delete on any day.** `delete_entry(entry_id)` is date-agnostic. To
   act on a past/future day, call `get_day(date)` first to find the entry's
   UUID, then `delete_entry`. To "replace yesterday's eggs":
   `get_day` → `delete_entry` → `log_food(..., consumed_at="<that day>")`.

## Scaling cheatsheet

`resolve_food` and `search_food` return macros at a `basis`. Compute the final
values before logging:

- `per_100g`: `final = per100 * grams / 100`. (150 g of a 165 kcal/100 g food →
  `165 * 150/100 = 248` kcal.)
- `per_serving`: multiply the per-serving macros by the number of servings.
- `per_unit`: multiply by the unit count (e.g. 3 eggs).

Round calories to an integer and macro grams to ~1 decimal. Pass the eaten
phrase as `quantity_text` ("150 g", "2 wraps") and, when you can, the parsed
amount as `normalized_quantity_value` / `normalized_quantity_unit`.

## Tool reference

**Search & log**
- `resolve_food(name)` — check memory first; returns `memory_usda`,
  `custom_food`, or `none`.
- `search_food(description, limit=3)` — USDA FoodData Central; **only** after a
  memory miss. Candidates carry a `basis`; scale before logging.
- `log_food(display_name, quantity_text, calories, protein_g, carbs_g, fat_g,
  fdc_id?/usda_description? | custom_food_id?, normalized_quantity_value?,
  normalized_quantity_unit?, consumed_at?)` — one entry, pre-scaled macros.
- `get_day(date?)` — entries + consumed totals + remaining-vs-target for a day
  (defaults to today). Your window into history and into finding entry IDs.
- `delete_entry(entry_id)` — delete by UUID (date-agnostic).

**Targets**
- `get_targets()` — current macro targets, or null.
- `set_targets(calories, protein_g, carbs_g, fat_g)` — upsert the target profile.

**Food memory** (per-user name → food mapping)
- `remember_food(name, fdc_id, usda_description, basis, calories, protein_g,
  carbs_g, fat_g, serving_size?, serving_size_unit?, aliases?)` — cache a USDA
  pointer keyed by name. Macros at `basis`, **not** scaled.
- `list_remembered_foods()` / `forget_food(name)` — audit & remove memory.
- `add_food_alias(name, alias)` / `remove_food_alias(name, alias)` — manage
  alternate phrasings that resolve to one entry.

**Custom foods** (user-defined, no USDA equivalent)
- `save_custom_food(name, basis, calories, protein_g, carbs_g, fat_g,
  serving_size?, serving_size_unit?, source?, notes?)` — create/update **and**
  write memory in one step. `source` ∈ `manual|photo|corrected`.
- `update_custom_food(custom_food_id, ...)` — partial update. Past entries keep
  their original macro snapshot; only future logs use new values.
- `list_custom_foods()` / `delete_custom_food(custom_food_id)` — delete fails if
  any entry or meal item still references it.

**Meals** (reusable named bundles of items, logged in one shot)
- `list_meals()` — lightweight summaries with totals; call early.
- `get_meal(meal_id? | name?)` — full meal with items.
- `create_meal(name, items, notes?, aliases?)` — each item needs exactly one of
  `usda_fdc_id` (+`usda_description`) or `custom_food_id`, with pre-scaled macros.
- `update_meal(meal_id, name?, notes?)` / `delete_meal(meal_id)`.
- `add_meal_item` / `update_meal_item` / `delete_meal_item` — item CRUD. Item
  food source can't be swapped in place; delete and re-add to change it.
- `add_meal_alias(meal_id, alias)` / `remove_meal_alias(meal_id, alias)`.
- `log_meal(meal_id, consumed_at?)` — log every item at its stored quantity;
  items share one `entry_group_id`. Never scale.

**Containers** (tare-aware meal-prep pots/boxes, in grams)
- `list_containers()` — each carries `tare_weight_g` (empty weight) to subtract
  from a scale reading.
- `save_container(name, tare_weight_g)` / `update_container(container_id, ...)` /
  `delete_container(container_id)`.

## Answering questions vs. logging

For "how many calories left today?", "what did I eat yesterday?", or "am I
hitting my protein?", read with `get_day` (and `get_targets` if not already in
the `get_day` response — it includes `remaining` when a target profile exists).
Don't log anything for a pure question. `LogFoodResponse` / `LogMealResponse`
also echo `day_totals` and `remaining_vs_target`, so after logging you can
report progress without a separate call.

## Error handling

- `delete`/`update` tools return `{"deleted": false}` or raise "… not found"
  when the id doesn't exist — surface that plainly instead of retrying.
- Name-collision errors ("a custom food/meal/container with that name already
  exists") mean the entity is already saved — fetch it instead of recreating.
- A `custom_food` can't be deleted while past entries or meal items reference
  it; tell the user rather than forcing it.
