# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. It is the **single doc for the whole monorepo** — the former per-subproject `CLAUDE.md`/`AGENTS.md` files were consolidated here. `AGENTS.md` at the root is a pointer to this file for Codex-style agents.

## Layout

This is a single git repo (monorepo) containing two subprojects for one product (the **Pulse** app — nutrition + weight + progress photos, single user today). Each was previously its own repo and was merged in with full history preserved under its subdirectory:

- `server/` — FastAPI + Postgres backend. Google-OAuth session/Bearer auth for the app; MCP endpoint at `/mcp` with GitHub-OAuth + service-token paths. Feature surface: food entries, meals, prep containers, custom foods, food memory, weight, progress photos (+ tags), USDA proxy. See **Server** below.
- `ios/` — SwiftUI iOS 17+ client (four tabs: Intake, Meals, Prep, Measures). Auth is Google sign-in → opaque Bearer session token (stored in Keychain); base URL is configured in Settings. The Login/AuthSession flow is the live and only client auth path. See **iOS** below.

There is no shared tooling or build at this level — `cd` into the relevant subdirectory before running anything. Each subproject keeps its own `.gitignore`; documentation lives only at the root (`README.md` + `CLAUDE.md` + the `AGENTS.md` pointer) — there are no nested READMEs.

## Cross-cutting contract

The two subprojects are coupled by a JSON-over-HTTP wire format, not a shared schema package. When you change a DTO on one side, you must update the other:

- Server DTOs: `server/src/pulse_server/models/` (Pydantic, `snake_case`).
- iOS DTOs: `ios/Pulse/Models/` (Codable structs, camelCase via explicit `CodingKeys` mapping `snake_case` JSON).
- iOS dates use `JSONDecoder.pulseDefault()` which accepts both `YYYY-MM-DD` and ISO-8601 — keep server outputs within those.
- The iOS client sends only `Authorization: Bearer <session token>` on every request — it does NOT append `?user_key=` and does NOT send `X-API-Key`. The server's `UserKeyGuardrailMiddleware` rejects any `?user_key=` query on protected routes with HTTP 400; the Google-OAuth → Bearer session-token flow is the live and only client auth path (the old user_key + X-API-Key path is gone). See **Server → Auth** below.

When extending features that span both sides, read both subprojects' `docs/superpowers/specs/` — that's where cross-cutting design decisions live.

---

## Server (`server/`)

### Commands

```bash
cd server

# Install deps
uv sync --extra dev

# Run server
uv run uvicorn pulse_server.app:app --port 8787 --reload

# Run all unit tests
uv run pytest tests/ -v

# Run a single test
uv run pytest tests/test_app.py::test_health_check -v

# Run integration tests (requires TEST_DATABASE_URL)
TEST_DATABASE_URL=postgresql://localhost/test uv run pytest -m integration -v

# Run migrations
uv run alembic upgrade head
```

### Architecture

FastAPI app using SQLAlchemy Core (not ORM) with async psycopg3. No ORM models — tables are defined as `Table` objects in `repositories/tables.py` and queries are built with SQLAlchemy expressions.

**Request flow:** router → service → repository. Routers own HTTP concerns, services handle business logic and transactions, repositories execute SQL.

**Feature surface** (`server/src/pulse_server/`):

- `routers/` — `auth`, `entries`, `summary`, `targets`, `usda`, `logs`, `containers`, `custom_foods`, `food_memory`, `meals`, `weight`, `measures_photos`, `measures_photo_tags`.
- `services/` — pairs 1:1 with routers for most features; plus `normalize.py`, `image_processing.py` (shared photo pipeline used by both container and progress photos), `alias_utils.py` (alias normalization) and `date_utils.py` (range/date validation), and `rate_limit.py`.
- `models/` — Pydantic DTOs (`snake_case`). Mirror these on the iOS side when changing wire format. `models/adapters.py` holds shared row→DTO adapters (`container_response`, `custom_food_response`, `food_memory_entry`, `meal_item_response`, `meal_response`, `meal_summary`, `macro_targets_from_row`) used by both routers and MCP tools. Tiny per-feature modules were merged into `models/daily.py` (logs + summary DTOs + `CaloriesDailyRow`).
- `auth/` — submodule: `google.py` (OAuth handshake), `sessions.py` (token issue/lookup), `middleware.py` (`SessionAuthMiddleware`, `UserKeyGuardrailMiddleware`, `GitHubAllowlistMiddleware`).
- `mcp/` — `server.py` holds only `build_mcp` + the auth-provider factories and mounts the MCP app at `/mcp`; `auth.py` wires GitHub OAuth + service-token paths via fastmcp `MultiAuth`. The tools are split into `mcp/tools/{food,meal,custom_food,container,memory,targets_summary}_tools.py` (each exposing a `register(mcp, ctx)`); MCP Pydantic models live in `mcp/models.py`, and a `ToolContext` plus shared helpers (`parse_consumed_at`, `target_and_remaining`, `basis_for`) live in `mcp/context.py`.
- `log_ids.py` (package root) — `daily_log_id` UUID5 day ids. `usda_provider.py` (package root) — provides the USDA client as a FastAPI dependency (resolved after lifespan startup). `macro_aggregates.py` — shared rollup math (`sum_food_entry_macros`, `remaining_macros`) used by summary/weight/photo services and MCP.

**Auth:** Google OAuth → opaque Bearer session tokens. `/auth/google/start` + `/auth/google/callback` run the handshake, issue a 32-byte URL-safe token, and store `sha256(token)` in the `sessions` table. `SessionAuthMiddleware` validates `Authorization: Bearer <token>` on every non-`/auth/*`/`/health` request and slides the TTL. Allowlist is `ALLOWED_EMAILS` (case-insensitive). `UserKeyGuardrailMiddleware` rejects any `?user_key=` query on protected routes (cutover guardrail; remove next release). Single-user today: `email_to_user_key` returns `LEGACY_USER_KEY`. MCP has two auth paths: GitHub OAuth (`GITHUB_CLIENT_ID/SECRET` + `PUBLIC_BASE_URL`) for interactive clients, and a static service token (`MCP_SERVICE_TOKEN`, min 32 chars) for headless agents — both can run together. `/mcp` is exempt from `SessionAuthMiddleware`; non-local startup refuses to boot unless GitHub OAuth, the service token, or `MCP_ALLOW_UNAUTH=true` is configured. The service token synthesizes a `login=service-account` claim that auto-joins any non-empty `ALLOWED_GITHUB_USERS`.

**Config (`config.py`):** `DATABASE_URL`, `USDA_API_KEY`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `OAUTH_REDIRECT_URI`, `APP_REDIRECT_SCHEME`, `ALLOWED_EMAILS`, `SESSION_TTL_DAYS`, `SESSION_TOKEN_BYTES`, `LEGACY_USER_KEY`, `PORT`, `TIMEZONE`, `APP_ENV`; MCP: `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `ALLOWED_GITHUB_USERS`, `PUBLIC_BASE_URL`, `MCP_SERVICE_TOKEN`, `MCP_ALLOW_UNAUTH`. HTTPS-required for OAuth redirect outside local-mode.

**DB lifecycle:** `db.py` manages a module-level SQLAlchemy async engine. `bootstrap_schema()` runs `schema.sql` idempotently on every startup (`IF NOT EXISTS`). Tables: `daily_target_profile`, `daily_logs`, `custom_foods`, `food_memory`, `meals`, `meal_items`, `food_entries`, `sessions`, `containers`, `progress_photo_tags`, `progress_photos`, `weight_entries`. Alembic available for migrations.

**Multi-user:** all data scoped by `user_key` (today: `LEGACY_USER_KEY`, e.g. `"khash"`). Daily logs use deterministic UUID5 from `(user_key, date)` via `log_ids.py` (package root) for idempotent upserts.

**Photos:** progress + container photos go through `services/image_processing.py` → JPEG bytes + thumbnail, stored inline in Postgres (no external blob store). Upload size is capped via `PhotoTooLargeError`.

**USDA integration:** `usda.py` wraps FoodData Central. `normalize_food_nutrients()` maps USDA IDs to the internal macro schema (calories=1008, protein=1003, carbs=1005, fat=1004).

**Tests:** unit tests mock the DB pool and USDA client. Integration tests require `TEST_DATABASE_URL` and are marked `pytest.mark.integration`; `tests/integration/conftest.py` bootstraps `schema.sql` once per session, and tests truncate tables between runs.

---

## iOS (`ios/`)

### Project

Single-user iOS client (SwiftUI, iOS 17+, Swift 5.9) for the self-hosted Pulse backend. Auth is Google sign-in: `Views/Auth/LoginView.swift` + `State/AuthSession.swift` drive an `ASWebAuthenticationSession` OAuth handshake (PKCE) that exchanges for an opaque Bearer session token, stored in Keychain via `KeychainStore`. The base URL is configured at runtime via Settings (→ `UserDefaults`).

**Auth:** the Google-OAuth → Bearer session-token flow is the live and only client auth path — the cutover is done. Every request carries `Authorization: Bearer <session token>`; there is no `user_key` / `X-API-Key` path anymore.

### Commands

The Xcode project is **generated** from `ios/project.yml` and gitignored. `PULSE_BASE_URL` (required) and `DEVELOPMENT_TEAM` (required for physical-device builds; leave unset for sim-only) must be exported in the shell at generate time — xcodegen bakes them into the pbxproj literally. Values live in `ios/.envrc` (gitignored, per-developer). Always regenerate before building after pulling or editing `project.yml`:

```bash
cd ios
source .envrc && xcodegen generate
```

When asked to "open Xcode" (or similar), run `source .envrc && xcodegen generate && open Pulse.xcodeproj` — never open the project without sourcing `.envrc` first, or builds will fail the prebuild URL check.

Build / test (CLI, from `ios/`):

```bash
xcodebuild -project Pulse.xcodeproj -scheme Pulse \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

xcodebuild -project Pulse.xcodeproj -scheme Pulse \
  -destination 'platform=iOS Simulator,name=iPhone 15' test

# single test
xcodebuild ... test -only-testing:PulseTests/PrepModelTests/testNetGramsSubtractsTare
```

The `ios/build/` directory is the local DerivedData (gitignored).

### Architecture

**Layers** (`ios/Pulse/`):

- `Networking/PulseClient.swift` — `actor` wrapping `URLSession`. Every request sets `Authorization: Bearer <session token>` (no `user_key` query, no `X-API-Key`). The actor holds only stored state, init, and the send helpers; per-domain methods live in `PulseClient+Food/Meals/Containers/Weight/Targets.swift` extensions over a shared `HTTPCore` value type (base URL + token + session + request-building / status-mapping / multipart primitives, also used by `ProgressPhotoClient`). `JSONDecoder.pulseDefault()` accepts both `YYYY-MM-DD` and ISO-8601 dates. Errors are normalized into `PulseError` (notSignedIn / unauthorized / notFound / payloadTooLarge / server / network / decoding).
- `Models/` — Codable wire DTOs mirroring the backend: `DailySummary`, `DailyLog`, `FoodEntry`, `Meal`, `Container`, `MacroTotals`/`MacroTargets`, `CaloriesDailyRow`, `WeightEntry`, `ProgressPhoto`, `WhoAmI`. `snake_case` JSON ↔ camelCase Swift via explicit `CodingKeys`. (Non-wire helper types live elsewhere: `PeriodBucket` and `FoodSearchResult` are in `State/`; `WeightFormatter` is in `Utilities/`.)
- `State/` — `@Observable` view models (no Combine). Pattern: each model holds a `weak var auth: AuthSession?`, calls `auth.makeClient()` on demand, and exposes a `LoadState<T>` (`.idle | .loading | .loaded(T) | .failed(PulseError)`). Models:
  - **Intake:** `DayMacroModel`, `PeriodIntakeModel(range:)` (one model for `.week`/`.month`/`.year`), `UserTargetsStore`. Day-row shaping lives in `DayRowTransforms.swift` (`groupDayEntries` + `clusterByProximity`); period `avg*` helpers are a `[DailyLog]` extension in `DailyLogAverages.swift`.
  - **Meals:** `MealsModel`.
  - **Prep:** `ContainersListModel`, `ContainerEditModel`, `PrepModel`.
  - **Measures:** `WeightLogModel`, `WeightTrendsModel`, `WeightAnalytics`, `ProgressPhotoStore`, `ProgressPhotoCache`, `ProgressPhotoTagStore`, `PhotoUploadQueue`.
  - **App-wide:** `AuthSession` (signed-in lifecycle, Keychain token, `makeClient()`), `LoadState`.
- `Views/` — SwiftUI. `RootView` owns four `NavigationStack`s (one per tab) and a `FloatingDock` overlay; the dock auto-hides when the active stack has pushed views. Tabs (`DockTab` enum):
  - **Intake** (`.intake`) — day/week/month/year macro views (`DayMacroView`, `WeekView`, `MonthView`, `YearView`, `LogView`).
  - **Meals** (`.meals`) — saved meal templates (`MealsView`, `MealDetailView`).
  - **Prep** (`.prep`) — tare-based portion calculator + container CRUD with photos (`Views/Prep/`).
  - **Measures** (`.measures`) — weight log + trends + progress photos with tags + side-by-side comparison + in-app camera (`Views/Measures/`).
  - Subfolders: `Components/` (shared view components reused across tabs — rings/bars/rows plus `EmptyStateView`, `MacroLineView`, `PrimaryActionButton`, `SectionCard`, `PeriodSummaryCard`), `Auth/` (`LoginView`).
- `Theme/Theme.swift` — Catppuccin Macchiato palette, dark only. Always style via `Theme.CTP.*` / `Theme.BG.*` / `Theme.FG.*` and the `.ctpCard()` view modifier — don't introduce raw `Color` literals or system grays.
- `Config/` — `Constants` (user key, defaults, keychain identifiers) and `KeychainStore` (Generic Password item with `kSecAttrAccessibleAfterFirstUnlock`).

**State-of-truth conventions worth preserving:**

- `PrepModel` stores the whole selected `Container`, not just an id+tare — keeps tare/selection drift impossible (see comment in file).
- `AuthSession.isSignedIn` gates the whole app: when false, `RootView` presents `LoginView` as a sheet to drive the Google OAuth sign-in.
- Container photo loads use `containerPhotoRequest(id:size:)` (a `nonisolated` factory on the actor) handed to `AuthorizedAsyncImage`, because `AsyncImage` itself can't add headers.

### Testing

`ios/PulseTests/` uses `StubURLProtocol` injected into an ephemeral `URLSession` to intercept requests and return JSON fixtures from `PulseTests/Fixtures/`. When adding endpoints, add a fixture and a client test rather than mocking the model layer.
