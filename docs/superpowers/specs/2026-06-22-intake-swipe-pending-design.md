# Intake Row Swipe Actions + Pending Badge — Design

- **Date:** 2026-06-22
- **Status:** Approved (pending spec review)
- **Spans:** `server/` + `ios/` (wire contract change)

## Goal

On the Intake day view, let the user swipe a food-entry row to either **delete**
it or **convert it to pending** (excluded from the day's totals/calculations).
Pending items are surfaced through a **count pill near the top** of the day view;
tapping the pill expands an inline panel listing every pending item, where each
can be **approved** (counted again) or left as-is.

This reuses the existing `confirmed` boolean that already drives prep-portion
pending state end-to-end. The only genuinely new server capability is the
**inverse** of confirm (confirmed → pending).

## Background: what already exists

- **Server:** `food_entries.confirmed boolean NOT NULL DEFAULT true`. Pending
  rows (`confirmed = false`) are already excluded from daily totals via
  `macro_aggregates.confirmed_entries`. `POST /entries/confirm` flips
  `false → true` (`repositories/entries.py::confirm_entries`,
  `services/entries_service.py::confirm_pending_entries`).
- **iOS:** `FoodEntry.isConfirmed`; pending rows render dimmed with a
  `PendingBadge`. The day view (`Views/DayMacroView.swift`) currently renders an
  **always-visible** "Pending" section at the top (`pendingSection`) with a
  "Confirm all" button and per-row confirm controls. Totals come pre-computed
  from the server in `DailySummary.consumed`.
- **Delete today:** multi-select mode + a Delete button →
  `DayMacroModel.deleteEntries` (per-row `DELETE /entries/{id}`, hard delete,
  treats 404 as success). No swipe affordance exists anywhere.

## Key constraint driving the approach

SwiftUI's built-in `.swipeActions` only works inside a `List`. The day view is
deliberately **not** a `List` — it is a `ScrollView` of bespoke `ctpCard`s with
alternating mauve tints and time-proximity clustering (`clusterCard`,
`clusteredEntries`). Converting to a `List` to get free swipe would flatten that
design.

**Chosen approach (A):** build a small reusable custom swipe component
(`SwipeActionsRow`) using a `DragGesture` that reveals trailing action buttons,
and wrap each row at its call sites. Preserves the clustered-card design exactly.

Rejected: (B) convert to `List` — loses tints/clustering/`ctpCard`; (C) context
menu — user explicitly asked for swipe.

## Design

### Server (mirror the confirm path)

1. **`repositories/entries.py` — `unconfirm_entries(entry_ids, user_key)`**
   Inverse of `confirm_entries`: `UPDATE food_entries SET confirmed = false
   WHERE id IN (...) AND user_key = ? AND confirmed IS true RETURNING <response
   columns>`. Idempotent — already-pending or non-matching ids are skipped, only
   actually-changed rows are returned.

2. **`services/entries_service.py` — `unconfirm_entries(session, user_key,
   entry_ids)`**
   Mirrors `confirm_pending_entries`: runs inside a transaction, enforces the
   same single-day guard (`ValueError` if changed rows span >1 daily log), and
   returns `(changed_rows, day_rows)` where `day_rows` is every entry on the
   affected daily log (for recomputing totals).

3. **`routers/entries.py` — `POST /entries/unconfirm`**
   New endpoint structurally identical to `POST /entries/confirm`. Request
   `EntriesPendingRequest { ids: [UUID] }` (≥1), response
   `EntriesPendingResponse { entries: [FoodEntryResponse], daily_totals:
   MacroTotals }` where `daily_totals = sum_food_entry_macros(confirmed_entries(
   day_entries))`. Maps the service `ValueError` to HTTP 422 (same as confirm).

   New Pydantic models live alongside the confirm models in `models/`. They are
   structurally identical to `EntriesConfirmRequest/Response`; kept as distinct
   named types for clarity/symmetry rather than reusing the confirm types.

### iOS client

4. **`Networking/PulseClient+Food.swift` — `makePending(ids:)`**
   `POST /entries/unconfirm` with `EntriesPendingRequest(ids:)` → returns
   `EntryWriteResponse` (same envelope confirm uses: entries + daily totals).
   Mirrors `confirmEntries(ids:)`.

5. **iOS wire models** — add `EntriesPendingRequest` (Codable, `{ids}`) mirroring
   `EntriesConfirmRequest`. Response decodes into the existing
   `EntryWriteResponse`.

6. **`State/DayMacroModel.swift` — `makePending(_ entries:)` + `pendingState`**
   Mirrors `confirmEntries` / `ConfirmState`: a `PendingState` enum
   (`idle | working | finished(count:) | failed(PulseError)`), an atomic call
   over the entries' ids, route 401 through `AuthSession`, reload the day on
   success. Empty input is a no-op. Delete continues to reuse `deleteEntries`.

### iOS UI

7. **New `Views/Components/SwipeActionsRow.swift`**
   Reusable wrapper: takes row content + an ordered list of trailing actions
   (label, system icon, tint, role, handler). A `DragGesture` translates the row
   left to reveal action buttons; tapping an action fires its handler and closes
   the row. Only one row open at a time is a nice-to-have, not required for v1.
   No full-swipe auto-trigger (every action requires an explicit button tap).
   Used in both the cluster cards and the pending panel.

8. **Confirmed rows (cluster cards in `clusterCard`)** wrap each `EntryRow` /
   `MealGroupRow` in `SwipeActionsRow` with actions:
   - **Make Pending** (tint mauve/pending) → `model.makePending(entries(of: row))`
   - **Delete** (tint red, destructive) → `model.deleteEntries(entries(of: row))`

9. **Replace the always-visible pending section with a count pill + expandable
   panel.**
   - Remove `pendingSection` from the default render path.
   - Add a **pending pill** (icon + "N pending") near the top, shown only when
     `pendingRows` is non-empty. Tapping toggles a `@State` expansion flag.
   - When expanded, render an inline panel listing the pending rows. Each row is
     a `SwipeActionsRow` with actions **Approve** (→ `model.confirmEntries`) and
     **Delete** (→ `model.deleteEntries`). Panel keeps an **Approve all** action
     (the existing `confirmAllBar` behavior). Collapsing the panel = "leave
     them."
   - Partition is unchanged: `groupDayEntries(summary.entries)` → rows with
     `hasPendingItems` feed the pill/panel; the rest render in the clusters.

10. **Meal-group rows** act on all items in the group (`group.items`), filtered
    to the relevant subset where it matters (Approve acts on the group's
    unconfirmed items, matching today's `pendingMealRow` behavior).

### Delete confirmation (open question for spec review)

Multi-select delete shows a confirmation dialog. For a **single** swipe-delete,
the lean is **no dialog** — the swipe-reveal plus button tap is already two
deliberate actions, and "Make Pending" now exists as the safe, reversible
alternative. Meal-group swipe-delete (removes several entries at once) may still
warrant a confirmation dialog. To be finalized at review.

## Data flow

1. User swipes a confirmed row → taps **Make Pending**.
2. `DayMacroModel.makePending([entry])` → `PulseClient.makePending(ids:)` →
   `POST /entries/unconfirm`.
3. Server flips `confirmed → false`, returns recomputed confirmed-only totals.
4. Model reloads the day (`load()`); the row leaves the cluster list and the
   pending pill count increments. Hero ring / `MacroTotalsRow` drop its macros.
5. Approve (in the panel or via swipe) is the inverse via the existing
   `confirmEntries` → `POST /entries/confirm`.

## Testing

**Server (pytest):**
- Unit: `unconfirm_entries` repo flips only currently-confirmed owned rows;
  idempotent; scopes by `user_key`.
- Unit/integration: `POST /entries/unconfirm` returns changed rows + correct
  recomputed `daily_totals`; 422 on cross-day ids; ignores already-pending ids.
- Round-trip: confirm then unconfirm restores prior totals.

**iOS (StubURLProtocol + fixtures):**
- `PulseClient.makePending` builds the right request and decodes
  `EntryWriteResponse` (new fixture).
- `DayMacroModel.makePending` transitions `pendingState` and reloads;
  unauthorized routes through `AuthSession`; empty input is a no-op.
- `SwipeActionsRow`: actions fire their handlers (logic-level test of the action
  list / handler wiring where feasible; visual behavior covered manually).

## Out of scope

- Multi-select "make pending" (only single-row + per-group for v1).
- Reordering / "one row open at a time" enforcement (nice-to-have).
- Any change to how totals are computed server-side (already correct).
