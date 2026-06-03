# Pulse Simplification Refactor — Report

_Generated 2026-06-03. Branch `refactor/simplify`. Goal: a smaller, walkable codebase with
identical features and identical iOS UI, plus high test coverage._

This document is meant to be read top-to-bottom once to understand **how Pulse is wired**,
then kept as a map. Part 1 is the architecture walkthrough (what each layer is and how a
request flows through it). Part 2 is what this refactor changed. Part 3 is coverage. Part 4
is recommended improvements that were intentionally **not** implemented.

---

## 0. Outcome at a glance

| | Before | After |
|---|---|---|
| Server tests | 252 (1 failing) | **390 passing** |
| Server line coverage | ~75% | **94%** |
| iOS tests | 200 | **270 passing** |
| iOS line coverage | ~78% | **87.9%** (structural cap — see §3) |
| Largest server file | `mcp/server.py` 1,463 LOC | **235 LOC** (split into 6 tool modules) |
| Behavior / UI | — | **Unchanged** (two opted-in MCP wire fixes + 2 latent bug fixes) |

Everything is behind one branch, intended to squash into a single PR. Each phase was committed
separately and gated against the full test suite of both subprojects before moving on.

---

## Part 1 — Architecture walkthrough

Pulse is a monorepo with two subprojects that talk over **JSON-over-HTTP** (no shared schema
package — the wire format is the contract):

```
pulse/
├── server/   FastAPI + Postgres (SQLAlchemy Core, no ORM)   ← REST for the app + MCP for AI agents
└── ios/      SwiftUI client (iOS 17+), four tabs
```

### 1A. Server — the four-layer stack

A request always flows **router → service → repository → Postgres**, and the response is built
from a **Pydantic DTO**. Each layer has exactly one job:

| Layer | Dir | Job | Rule of thumb |
|---|---|---|---|
| **Router** | `routers/` | HTTP only: parse request, map errors to status codes, pick a `response_model`. | No SQL, no business rules. |
| **Service** | `services/` | Business logic + transaction boundaries; orchestrates repositories. | Owns `async with transaction(...)`. |
| **Repository** | `repositories/` | All SQL (SQLAlchemy Core expressions over `Table` objects in `tables.py`); returns plain `dict` rows. | The only layer allowed to issue SQL. |
| **Model / adapter** | `models/` | Pydantic DTOs (`snake_case`) + `models/adapters.py` row→DTO adapters. | The wire contract. Mirror on iOS when changed. |

Supporting pieces (all at `src/pulse_server/`):
- `app.py` — composition root: lifespan (DB pool + USDA client), installs `SessionAuthMiddleware` + `UserKeyGuardrailMiddleware`, registers the 13 routers, mounts the MCP app at `/mcp`.
- `db.py` — async engine lifecycle, `get_session_dependency`, `transaction()` context manager, `bootstrap_schema()` (runs `schema.sql` idempotently on startup).
- `config.py` — `pydantic-settings`; all env config + validators.
- `auth/` — `google.py` (OAuth handshake), `sessions.py` (token issue/lookup), `middleware.py` (Bearer validation + the `?user_key=` guardrail).
- `mcp/` — the AI-agent surface (see §1C).
- `log_ids.py`, `usda_provider.py`, `macro_aggregates.py`, `usda.py` — small shared utilities.

**Auth (one path now):** Google OAuth → opaque **Bearer session token** (sha256 stored in
`sessions`). `SessionAuthMiddleware` validates `Authorization: Bearer <token>` on every
non-`/auth/*`, non-`/health` request and slides the TTL. The old `?user_key=` + `X-API-Key`
path is **gone** — `UserKeyGuardrailMiddleware` now returns HTTP 400 if a client sends
`?user_key=`. Internally, all rows are still scoped by `user_key` (`email_to_user_key` returns
`LEGACY_USER_KEY` = `"khash"` — the single documented multi-user seam).

### 1B. iOS — the layered SwiftUI client

| Layer | Dir | Job |
|---|---|---|
| **Views** | `Pulse/Views/` | SwiftUI. `RootView` owns four `NavigationStack`s (one per tab) + a `FloatingDock`. Shared pieces in `Views/Components/`. |
| **State** | `Pulse/State/` | `@Observable` view-models (no Combine). Each holds `weak var auth: AuthSession?`, calls `auth.makeClient()`, and exposes `LoadState<T>`. |
| **Networking** | `Pulse/Networking/` | `PulseClient` actor (split into `PulseClient+Food/Meals/Containers/Weight/Targets`) over a shared `HTTPCore`; `ProgressPhotoClient` for image bytes. |
| **Models** | `Pulse/Models/` | Codable wire DTOs, `snake_case`↔camelCase via `CodingKeys`. |

The four tabs (`DockTab`): **Intake** (day/week/month/year macros), **Meals** (saved templates),
**Prep** (tare-based portioning + container CRUD), **Measures** (weight + trends + progress
photos + comparison + camera). `AuthSession.isSignedIn` gates the whole app — when false,
`RootView` presents `LoginView`.

### 1C. The MCP surface (AI-agent contract)

`/mcp` exposes 31 tools to MCP clients (e.g. Claude in claude.ai). After this refactor the MCP
code mirrors the server's layering instead of duplicating it:
- `mcp/server.py` — `build_mcp()` + auth-provider factories only.
- `mcp/context.py` — `ToolContext(user_key, tz, usda_getter)` + helpers.
- `mcp/models.py` — MCP Pydantic models.
- `mcp/tools/{food,meal,custom_food,container,memory,targets_summary}_tools.py` — each a
  `register(mcp, ctx)`. Tools call the **same services and `models/adapters.py`** the REST
  routers use, so the two surfaces can't drift.

### 1D. The end-to-end flows (read these to trace any feature)

**Log a food (REST):** iOS `DayMacroView`/copy-flow → `PulseClient.createEntries` → `POST /entries`
(`routers/entries.py`) → `entries_service.create_entries_with_side_effects` (memory upsert +
daily-log creation, one transaction) → `EntriesRepository` → returns `{entries, daily_totals}`.

**Log a food (MCP):** agent → `resolve_food(name)` (memory hit?) → else `search_food` (USDA) →
`log_food` (`mcp/tools/food_tools.py`) → same `entries_service` → returns
`{entry, daily_totals, target, remaining_vs_target}` (now `daily_totals`, matching REST).

**Log a meal:** iOS `MealDetailView` → `POST /meals/{id}/log`; MCP `log_meal`. Both expand the
meal's items into individual entries sharing an `entry_group_id` via `meals_service`.

**Food memory + aliases:** `resolve_food` → `food_memory_service.resolve_food_by_name`; writes via
`PUT /food-memory/*` or MCP `remember_food`/`add_food_alias`. Both REST and MCP responses now
include `aliases` (previously REST silently dropped it).

**Prep containers:** iOS Prep tab → `PulseClient+Containers` → `/containers` CRUD + photo
(`image_processing.process_photo` → JPEG full+thumb stored as BYTEA). Containers are a tare aid;
`PrepModel` owns the selected container + persistence.

**Weight + trends:** `WeightLogView`/`WeightTrendsView` → `/weight` + `/calories_daily`.
Regression math lives in `WeightTrendsModel` (moved out of the view); analytics in `WeightAnalytics`.

**Progress photos:** `PhotoCaptureSession` → `PhotoUploadQueue` → `ProgressPhotoClient` →
`/measures/photos` (idempotency-keyed) → `image_processing`. Download via metadata list + SHA cache
(`ProgressPhotoStore`/`ProgressPhotoCache`).

**Auth:** `LoginView` → `AuthSession` (PKCE via `ASWebAuthenticationSession`) →
`/auth/google/start`→`callback`→`exchange` → Bearer token in Keychain → every request carries it.

**Daily summary:** `GET /summary/{date}` → `summary_service.build_daily_summary` (404 when no
target profile — the iOS app relies on this, so it was deliberately left unchanged).

---

## Part 2 — What this refactor changed

Eight phases, each behavior-preserving and test-gated. The UI was never touched except by moving
code verbatim into shared components.

- **Phase 0 — Safety net.** Fixed a pre-existing failing test (`test_tag_create_list_rename`: a
  bare read autobegan a transaction so the next `transaction()` could not `begin()`). Added
  `tests/integration/conftest.py` so the integration suite bootstraps `schema.sql` once and no
  longer depends on test ordering (it failed on a fresh DB before).
- **Phase 1 — Dead code.** Removed `services/container_photos.py` pass-through, the dead
  `repositories/__init__.py` re-exports, iOS `AppSettings` (empty, unused), `ContainerPhotoStatus`,
  and the unused `DateOnlyFormatter`.
- **Phase 2 — Server de-duplication.** `services/alias_utils.py` + `date_utils.py` (killed
  duplicated alias/validation helpers); `MacroFields` base model; merged `models/logs`+`summary`
  into `models/daily.py`; `custom_foods` `create`/`upsert` merged; `FoodEntryPayload` dataclass for
  an 18-arg signature; `daily_log_id` moved to package root to fix a repo→service import; USDA
  client became a FastAPI dependency (removed a circular-import hack).
- **Phase 3 — MCP decomposition.** `mcp/server.py` 1,463 → 235 LOC, tools split into 6 modules.
  `models/adapters.py` is the single source of truth for row→DTO adapters used by **both** routers
  and MCP. **Opted-in wire fixes:** REST meal/food-memory responses now include `aliases`
  (additive; iOS ignores unknown keys); MCP `day_totals` → `daily_totals` (matches REST). **Bug
  fix:** `add_meal_alias`'s append path errored in production (same transaction-autobegin defect)
  — now fixed.
- **Phase 4 — iOS networking.** Shared `HTTPCore` (was duplicated across both clients); `PulseClient`
  split by domain; `JSONSerialization` write paths replaced with Codable; unified photo-size enum;
  merged grouping files; moved regression math into the model; relocated non-wire types.
- **Phase 5 — iOS views.** Extracted `EmptyStateView`, `MacroLineView`, `PrimaryActionButton`,
  `SectionCard`, `PeriodSummaryCard` (verbatim — identical modifiers); split `CopyEntriesSheet`
  out of `DayMacroView`; merged `Week/Month/YearModel` into one `PeriodIntakeModel(range:)`; moved
  `saveTarget`/Prep lifecycle into their models; unified the camera bridge.
- **Phase 6 — Coverage.** Server 80→94%, iOS 78→87.9% (see §3).
- **Phase 7 — Docs.** Corrected the stale auth narrative (the docs still described the dead
  `user_key`/`X-API-Key` path as live) and the renamed/removed types, then consolidated all
  documentation into a single root `CLAUDE.md` (the per-subproject `CLAUDE.md`/`AGENTS.md`
  copies had drifted and were removed; root `AGENTS.md` is now a pointer).

### Notable findings surfaced along the way
1. **The legacy auth path was already dead in code but "live" in docs.** The server rejects
   `?user_key=` and iOS is Bearer-only — but every doc said otherwise. Corrected.
2. **Two instances of the same transaction-autobegin bug** (`test_tag_create_list_rename` and
   the MCP `add_meal_alias` append path). Both fixed.
3. **Integration tests only passed by luck of alphabetical ordering** (only 2 of 6 files bootstrap
   the schema). Fixed with a shared conftest.

---

## Part 3 — Coverage

**Server: 94%** (390 tests). Every REST router and MCP tool now has behavior tests; the residual
is mostly defensive `IntegrityError`/`HTTPException` re-wrap branches.

**iOS: 87.9%** (270 tests). The remaining gap to 90% is a **structural ceiling**, not missing
effort — ~1,536 lines that XCTest cannot reach without UI automation or app-code test seams:
- SwiftUI `Button`/`Menu` action closures register no tappable control in a `UIHostingController`
  tree, so their bodies can't be invoked from unit tests (~1,044 lines across ~10 views).
- `PhotoCaptureSession`'s captured-photo UI is gated behind camera/PhotosPicker callbacks (~370 lines).
- `AuthSession`'s `ASWebAuthenticationSession` web flow can't run headless (~122 lines).

Reaching 90% would require either an XCUITest target driving real taps, or small behavior-preserving
testability seams in the views — both declined to keep the app code untouched. The **combined**
project is ~91%.

---

## Part 4 — Recommended improvements (NOT implemented)

These were catalogued during the audit and intentionally left for you to decide on, because each
changes runtime behavior, infrastructure, or the wire format beyond the pure simplification scope.

### Performance
- **Move photo blobs out of Postgres.** `progress_photos` + `containers` store JPEG bytes inline as
  `BYTEA`. This bloats WAL/backups; a filesystem or object store (S3) is the standard fix.
- **Cache the session lookup.** `SessionAuthMiddleware` does a `SELECT` + slide-`UPDATE` on every
  authenticated request. A short-lived in-process cache would cut two DB round-trips per request.
- **`asyncio.Lock` in the rate limiter.** `services/rate_limit.py` uses `threading.Lock` inside an
  async handler — architecturally wrong (can block the event loop), though low-impact today.
- **Cache `auth.makeClient()` on iOS.** It reads the Keychain on every model call.

### Security / correctness
- **Cap & prune the `sessions` table** (no per-device cap, expired rows accumulate).
- **`PulseError.server(status: -1)`** is thrown for non-HTTP responses (connectivity/redirect) —
  wrong taxonomy; should map to a network error.
- **`AuthorizedAsyncImage`** keys identity by URL+headers correctly but loads via
  `URLSession.shared`, which writes to the shared disk cache.
- **MCP identity is hardcoded** to `LEGACY_USER_KEY` regardless of which GitHub user authenticates
  (fine for single-user; revisit before multi-user).

### UX-preserving
- **ETag / conditional-GET on `/summary` and `/entries`** (the app polls them on every day view).
- **First-time `/summary` 404 → friendlier empty state** (today the iOS app shows a failed state
  when no target profile exists). _Note: this is why the 404 was deliberately preserved — changing
  it changes the iOS UI, which was out of scope._

### Data integrity
- **Upload-worker duplicate POSTs.** The worker can issue a duplicate POST for an in-flight item;
  the server idempotency key is a safety net, not the design. Worth tightening the worker's
  in-flight guard.

### Tech-debt seams
- `email_to_user_key` always returns `LEGACY_USER_KEY` — the documented single→multi-user seam.
- The `/logs` range endpoint has **no max-span cap** (unlike `/weight` and the calorie trend), so a
  client can request an arbitrarily wide window. Confirm whether that's intentional.

---

## How to verify locally

```bash
# Server (needs a Postgres; tests bootstrap the schema themselves)
cd server && export TEST_DATABASE_URL="postgresql://.../pulse_test"
uv run --with pytest-cov pytest tests/ --cov=pulse_server --cov-report=term

# iOS
cd ios && source .envrc && xcodegen generate
xcodebuild test -project Pulse.xcodeproj -scheme Pulse \
  -destination 'platform=iOS Simulator,name=<your sim>' -enableCodeCoverage YES
```
