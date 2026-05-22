# diet-tracker-server

Backend for a self-hosted nutrition / meal-prep tracker. FastAPI + Postgres, single-user today (gated by Google OAuth allowlist), exposed both as a JSON HTTP API for the iOS client and as an MCP server for Claude.

Paired with [`diet-tracker-ios`](../diet-tracker-ios) — same product, two repos coupled only by the JSON wire format.

## What it does

- **Food logging.** Per-day entries with macros (kcal/protein/carbs/fat) and meal grouping (breakfast/lunch/dinner/snacks). Daily, weekly, monthly, yearly rollups.
- **USDA FoodData Central search + resolve.** Maps USDA nutrient IDs to the internal macro schema.
- **Custom foods + food memory.** Save your own foods, remember USDA picks under a name, attach aliases so "chicken" maps to the same thing every time.
- **Meals.** Composable meal templates (a list of items with quantities) that you can log in one shot.
- **Containers.** Tare-aware meal-prep containers with optional photo. The Prep flow on iOS uses these to compute net grams from gross weight.
- **Targets.** Per-user daily macro targets.
- **MCP endpoint.** Same domain exposed as 30 MCP tools at `/mcp` so Claude can search, log, manage meals/containers/custom-foods directly.

## Auth

Google OAuth → opaque Bearer session tokens.

- `/auth/google/start` + `/auth/google/callback` run the OAuth handshake, issue a 32-byte URL-safe token, store `sha256(token)` in `sessions`.
- `SessionAuthMiddleware` validates `Authorization: Bearer <token>` on every non-`/auth/*`/`/health` request and slides TTL.
- Allowlist: `ALLOWED_EMAILS` (case-insensitive, comma-separated).
- `UserKeyGuardrailMiddleware` rejects any `?user_key=` query on protected routes (cutover guardrail; remove next release).
- Single-user today: `email_to_user_key` returns `LEGACY_USER_KEY`.
- MCP has its own GitHub-OAuth path (`GITHUB_CLIENT_ID/SECRET` + `PUBLIC_BASE_URL`) for interactive clients (claude.ai, Claude Desktop) and a static service-token path (`MCP_SERVICE_TOKEN`, min 32 chars) for headless agents. Either is sufficient; both can run together via `MultiAuth`. `/mcp` is exempt from session auth. Non-local startup refuses to boot unless GitHub OAuth, the service token, or `MCP_ALLOW_UNAUTH=true` is configured. The service token synthesizes a `login=service-account` claim that auto-joins any non-empty `ALLOWED_GITHUB_USERS`.

## Architecture

FastAPI with **SQLAlchemy Core** (not ORM), **async psycopg3** pool. Tables defined as `Table` objects in `repositories/tables.py`; queries built with SQLAlchemy expressions.

Request flow: **router → service → repository.** Routers own HTTP, services own business logic + transactions, repositories execute SQL.

```
src/diet_tracker_server/
├── app.py                 FastAPI factory, lifespan, middleware wiring, MCP mount
├── config.py              pydantic-settings env loader
├── db.py                  async engine + bootstrap_schema() (idempotent schema.sql)
├── usda.py                FoodData Central HTTP client + nutrient normalization
├── macro_aggregates.py    daily/weekly/monthly/yearly rollup math
├── auth/
│   ├── google.py          OAuth handshake
│   ├── sessions.py        token issue / validate / slide
│   └── middleware.py      SessionAuthMiddleware, UserKeyGuardrailMiddleware
├── routers/               HTTP endpoints (entries, summary, targets, usda, logs,
│                          containers, custom_foods, food_memory, meals, auth)
├── services/              log_ids (UUID5), food_memory_service, normalize
├── repositories/          SQL queries per table
├── models/                Pydantic request/response DTOs (snake_case)
└── mcp/
    ├── server.py          30 MCP tools wrapping the same domain
    └── auth.py            GitHub OAuth provider for MCP
```

**DB lifecycle.** `bootstrap_schema()` runs `schema.sql` on startup using `IF NOT EXISTS`. Alembic is wired up for migrations; the base schema is bootstrapped, deltas live in `alembic/versions/`.

**Multi-user shape.** All data is scoped by `user_key`. Today every request resolves to `LEGACY_USER_KEY` (`"khash"`). Daily logs use deterministic UUID5 from `(user_key, date)` so the same day always idempotently upserts.

## Commands

```bash
# Install
uv sync --extra dev

# Run server
uv run uvicorn diet_tracker_server.app:app --port 8787 --reload

# Unit tests
uv run pytest tests/ -v

# Integration tests (requires TEST_DATABASE_URL)
TEST_DATABASE_URL=postgresql://localhost/test uv run pytest -m integration -v

# Migrations
uv run alembic upgrade head
```

## Config

Required env: `DATABASE_URL`, `USDA_API_KEY`. Optional: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `OAUTH_REDIRECT_URI`, `APP_REDIRECT_SCHEME`, `ALLOWED_EMAILS`, `SESSION_TTL_DAYS`, `LEGACY_USER_KEY`, `APP_ENV`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `ALLOWED_GITHUB_USERS`, `PUBLIC_BASE_URL`, `MCP_ALLOW_UNAUTH`, `MCP_SERVICE_TOKEN`.

## Deploy

Dockerized; Railway-targeted (`railway.json`, healthcheck `/health`). The Dockerfile uses `uv sync --frozen --no-dev` against `uv.lock`.

## Wire-format contract with iOS

JSON over HTTP, `snake_case` keys. iOS Codable structs in `diet-tracker-ios/DietTracker/Models/` mirror the Pydantic DTOs in `src/diet_tracker_server/models/` via explicit `CodingKeys`. iOS accepts both `YYYY-MM-DD` and ISO-8601 dates — keep server outputs within those.
