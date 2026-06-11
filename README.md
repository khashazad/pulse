# Pulse

Self-hosted nutrition / weight / progress tracker. Single user today. One monorepo, two subprojects coupled only by a JSON-over-HTTP wire format:

- [`server/`](server/) — FastAPI + Postgres backend, also exposed as an MCP server for Claude.
- [`ios/`](ios/) — SwiftUI iOS 17+ client.

There is no shared tooling at the root — `cd` into the relevant subdirectory before running anything.

## Server

FastAPI + Postgres backend. JSON HTTP API for the iOS client, plus an MCP endpoint at `/mcp` so Claude can use the same domain directly.

### What it does

- **Food logging.** Per-day entries with macros (kcal/protein/carbs/fat) and meal grouping (breakfast/lunch/dinner/snacks). Daily, weekly, monthly, yearly rollups.
- **USDA FoodData Central search + resolve.** Maps USDA nutrient IDs to the internal macro schema.
- **Custom foods + food memory.** Save your own foods, remember USDA picks under a name, attach aliases so "chicken" maps to the same thing every time.
- **Meals.** Composable meal templates (a list of items with quantities) logged in one shot.
- **Containers.** Tare-aware meal-prep containers with optional photo. The Prep tab on iOS uses these to compute net grams from gross weight.
- **Weight + progress photos.** Weight entries with trends, progress photos with tags; photos are processed into archive/display/thumb JPEGs and stored in an S3-compatible object store (Backblaze B2 in production, local filesystem in dev) — Postgres keeps metadata only. Container photos remain inline BYTEA.
- **Targets.** Per-user daily macro targets.
- **MCP endpoint.** The same domain exposed as MCP tools at `/mcp`.

### Auth

Google OAuth → opaque Bearer session tokens.

- `/auth/google/start` + `/auth/google/callback` run the handshake, issue a 32-byte URL-safe token, and store `sha256(token)` in the `sessions` table.
- `SessionAuthMiddleware` validates `Authorization: Bearer <token>` on every non-`/auth/*`/`/health` request and slides the TTL once a session passes half its lifetime. The unauthenticated `/auth/google/*` routes are rate-limited per client IP. Allowlist: `ALLOWED_EMAILS` (case-insensitive).
- The Bearer session token is the only client auth path; the legacy `?user_key=` query parameter is not part of the auth surface and is ignored.
- MCP has two auth paths: GitHub OAuth (`GITHUB_CLIENT_ID/SECRET` + `PUBLIC_BASE_URL`) for interactive clients, and a static service token (`MCP_SERVICE_TOKEN`, min 32 chars) for headless agents. Both can run together. `/mcp` is exempt from session auth; non-local startup refuses to boot unless GitHub OAuth, the service token, or `MCP_ALLOW_UNAUTH=true` is configured.

### Architecture

FastAPI with **SQLAlchemy Core** (not ORM) and an **async psycopg3** pool. Tables are `Table` objects in `repositories/tables.py`; queries are SQLAlchemy expressions.

Request flow: **router → service → repository.** Routers own HTTP, services own business logic + transactions, repositories execute SQL.

- `routers/` — `auth`, `entries`, `summary`, `targets`, `usda`, `logs`, `containers`, `custom_foods`, `food_memory`, `meals`, `weight`, `measures_photos`, `measures_photo_tags`.
- `services/` — pairs 1:1 with routers, plus shared helpers (`image_processing.py`, `normalize.py`, `rate_limit.py`, …).
- `models/` — Pydantic DTOs (`snake_case`), mirrored on the iOS side.
- `auth/` — Google OAuth handshake, session tokens, middleware.
- `mcp/` — MCP server, GitHub OAuth + service-token auth, tools split per feature.

**DB lifecycle.** `bootstrap_schema()` runs `schema.sql` idempotently on every startup — that file is the single source of truth for the schema. Changes land as idempotent guarded statements and are folded into the final-shape DDL once deployed everywhere. All data is scoped by `user_key` (today: `LEGACY_USER_KEY`). Daily logs use deterministic UUID5 from `(user_key, date)` for idempotent upserts.

### Commands

```bash
cd server

uv sync --extra dev                                          # install
uv run uvicorn pulse_server.app:app --port 8787 --reload     # run
uv run pytest tests/ -v                                      # unit tests
TEST_DATABASE_URL=postgresql://localhost/test uv run pytest -m integration -v
```

### Config

Required env: `DATABASE_URL`, `USDA_API_KEY`. Optional: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `OAUTH_REDIRECT_URI`, `APP_REDIRECT_SCHEME`, `ALLOWED_EMAILS`, `SESSION_TTL_DAYS`, `LEGACY_USER_KEY`, `APP_ENV`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `ALLOWED_GITHUB_USERS`, `PUBLIC_BASE_URL`, `MCP_SERVICE_TOKEN`, `MCP_ALLOW_UNAUTH`.

### Deploy

Dockerized; Railway-targeted (`server/railway.json`, healthcheck `/health`). The Dockerfile runs `uv sync --frozen --no-dev` against `uv.lock`.

## iOS

SwiftUI iOS 17+ client. Auth is Google sign-in → opaque Bearer session token (stored in Keychain); the base URL is configured in Settings. Dark only, Catppuccin Macchiato palette.

### Tabs

- **Intake** — day/week/month/year views of food entries with macro totals, kcal bar charts, macro rings, and per-occasion day cards.
- **Meals** — browse saved meal templates, log a meal in one tap.
- **Prep** — tare-aware portion calculator plus container CRUD with photos.
- **Measures** — weight log + trends, progress photos with tags, side-by-side comparison, in-app camera.

### Architecture

- `Networking/PulseClient.swift` — `actor` over `URLSession`; every request sends `Authorization: Bearer <session token>`. Per-domain methods live in `PulseClient+*.swift` extensions over a shared `HTTPCore`. Errors normalize to `PulseError`.
- `Models/` — Codable DTOs mirroring the backend (`snake_case` JSON ↔ camelCase Swift via explicit `CodingKeys`).
- `State/` — `@Observable` view models (no Combine). Each holds `weak var auth: AuthSession?`, calls `auth.makeClient()` on demand, and exposes `LoadState<T>`.
- `Views/` — `RootView` owns four `NavigationStack`s (one per tab) and a `FloatingDock` overlay.
- `Theme/Theme.swift` — Catppuccin palette; style via `Theme.CTP.*` / `.ctpCard()`, no raw `Color` literals.

### Build

The Xcode project is **generated** from `ios/project.yml` and gitignored. `PULSE_BASE_URL` (required) and `DEVELOPMENT_TEAM` (for device builds) are baked in at generate time; values live in `ios/.envrc` (gitignored).

```bash
cd ios
source .envrc && xcodegen generate
open Pulse.xcodeproj
```

CLI:

```bash
xcodebuild -project Pulse.xcodeproj -scheme Pulse \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

xcodebuild -project Pulse.xcodeproj -scheme Pulse \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

### Testing

`ios/PulseTests/` uses `StubURLProtocol` injected into an ephemeral `URLSession` to return JSON fixtures from `PulseTests/Fixtures/`. When adding endpoints, add a fixture and a client test rather than mocking the model layer.

## Wire-format contract

JSON over HTTP, `snake_case` keys. Server DTOs in `server/src/pulse_server/models/` (Pydantic) are mirrored by iOS Codable structs in `ios/Pulse/Models/` via explicit `CodingKeys`. iOS dates accept both `YYYY-MM-DD` and ISO-8601 — keep server outputs within those. When you change a DTO on one side, update the other.
