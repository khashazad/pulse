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
   success. Empty input is a no-op.

   **Deferred-delete buffer (new).** Add `requestDelete(_ entries:)`,
   `undoDelete()`, and a published `pendingDelete` (the buffered entries +
   remaining-seconds, `nil` when none) that the view observes to show the undo
   snackbar:
   - `requestDelete`: first flush any outstanding deferred delete, snapshot the
     current loaded `DailySummary`, optimistically mutate the loaded summary
     (remove the rows; subtract each **confirmed** entry's macros from
     `consumed` — pending entries don't affect `consumed`), then start a 10s
     cancellable commit `Task`.
   - On expiry the task calls the existing `deleteEntries` then `load()` to
     reconcile; partial-failure handling stays as today (the existing retry
     alert).
   - `undoDelete`: cancel the task, restore the snapshot, clear `pendingDelete`.
   - A `flushPendingDelete()` is invoked on `.onDisappear` / scenephase
     background so a deferred delete commits rather than silently vanishing.

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
   - **Delete** (tint red, destructive) → single food row: `model.requestDelete(
     [entry])` directly (no dialog). Meal-group row: present the destructive
     confirmation dialog; on confirm → `model.requestDelete(group.items)`.

   An **undo snackbar** (new lightweight component, sibling to the existing
   `TransientConfirmation`) is shown whenever `model.pendingDelete != nil`,
   with a 10s countdown and an **Undo** button calling `model.undoDelete()`.

9. **Replace the always-visible pending section with a count pill + expandable
   panel.**
   - Remove `pendingSection` from the default render path.
   - Add a **pending pill** (icon + "N pending") near the top, shown only when
     `pendingRows` is non-empty. Tapping toggles a `@State` expansion flag.
   - When expanded, render an inline panel listing the pending rows. Each row is
     a `SwipeActionsRow` with actions **Approve** (→ `model.confirmEntries`) and
     **Delete** (→ `model.requestDelete`, same deferred-delete + undo path).
     Panel keeps an **Approve all** action
     (the existing `confirmAllBar` behavior). Collapsing the panel = "leave
     them."
   - Partition is unchanged: `groupDayEntries(summary.entries)` → rows with
     `hasPendingItems` feed the pill/panel; the rest render in the clusters.

10. **Meal-group rows** act on all items in the group (`group.items`), filtered
    to the relevant subset where it matters (Approve acts on the group's
    unconfirmed items, matching today's `pendingMealRow` behavior).

### Delete behavior: no confirm for single rows, confirm for meals, 10s undo

Resolved:

- **Single food row** swipe-delete: **no confirmation dialog**.
- **Meal-group** swipe-delete (removes several entries at once): show a
  **confirmation dialog** first (reusing the existing destructive-dialog style).
- **All** swipe-deletes (single and, after the meal dialog is confirmed,
  meal-group) then enter a **10-second undo window**.

**Mechanism — deferred (optimistic) delete.** The server `DELETE` is a *hard*
delete with no trash table, so undo cannot un-delete after the fact. Instead the
delete is deferred:

1. On delete, the model optimistically removes the entries from its in-memory
   `DailySummary` (drops the rows **and** subtracts their macros from `consumed`
   so the ring, `MacroTotalsRow`, list, and pending pill all update at once) and
   snapshots the pre-delete summary. No server call yet.
2. An **undo snackbar** appears with a countdown / **Undo** button for 10s.
3. **Undo** within the window: restore the snapshot, cancel the commit. No
   server request was ever sent.
4. **Window expires** (or the user triggers another delete, or the view
   disappears / app backgrounds — all flush the buffer): fire the actual
   `DELETE /entries/{id}` per entry via the existing `deleteEntries`, then
   reload the day to reconcile.

Only one outstanding deferred-delete at a time: starting a new delete commits the
previous one first.

Note: if the app is force-killed inside the 10s window, the entries survive on
the server (the `DELETE` never fired) — acceptable and fail-safe.

"Make Pending" needs no undo: it is already reversible via Approve.

## Data flow

1. User swipes a confirmed row → taps **Make Pending**.
2. `DayMacroModel.makePending([entry])` → `PulseClient.makePending(ids:)` →
   `POST /entries/unconfirm`.
3. Server flips `confirmed → false`, returns recomputed confirmed-only totals.
4. Model reloads the day (`load()`); the row leaves the cluster list and the
   pending pill count increments. Hero ring / `MacroTotalsRow` drop its macros.
5. Approve (in the panel or via swipe) is the inverse via the existing
   `confirmEntries` → `POST /entries/confirm`.

**Delete flow:** swipe **Delete** → (meal: confirm dialog →) `requestDelete`
optimistically removes rows + adjusts totals locally and shows the undo
snackbar; after 10s the buffered `DELETE`s fire and the day reloads, or **Undo**
restores the snapshot with no request sent.

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
- `DayMacroModel` deferred delete: `requestDelete` optimistically removes rows
  and subtracts only confirmed entries' macros from `consumed`; `undoDelete`
  restores the snapshot and sends **no** request; expiry/flush commits the
  `DELETE`s and reloads; a second `requestDelete` flushes the first.
- `SwipeActionsRow`: actions fire their handlers (logic-level test of the action
  list / handler wiring where feasible; visual behavior covered manually).

## Out of scope

- Multi-select "make pending" (only single-row + per-group for v1).
- Reordering / "one row open at a time" enforcement (nice-to-have).
- Any change to how totals are computed server-side (already correct).
