# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
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

## Architecture

FastAPI app using SQLAlchemy Core (not ORM) with async psycopg3. No ORM models — tables are defined as `Table` objects in `repositories/tables.py` and queries are built with SQLAlchemy expressions.

**Request flow:** router → service → repository. Routers own HTTP concerns, services handle business logic and transactions, repositories execute SQL.

**Feature surface** (`src/pulse_server/`):

- `routers/` — `auth`, `entries`, `summary`, `targets`, `usda`, `logs`, `containers`, `custom_foods`, `food_memory`, `meals`, `weight`, `measures_photos`, `measures_photo_tags`.
- `services/` — pairs 1:1 with routers for most features; plus `log_ids.py` (UUID5 day ids), `normalize.py`, `image_processing.py` (shared photo pipeline used by both container and progress photos).
- `models/` — Pydantic DTOs (`snake_case`). Mirror these on the iOS side when changing wire format.
- `auth/` — submodule: `google.py` (OAuth handshake), `sessions.py` (token issue/lookup), `middleware.py` (`SessionAuthMiddleware`, `UserKeyGuardrailMiddleware`, `GitHubAllowlistMiddleware`).
- `mcp/` — `server.py` mounts the MCP app at `/mcp`; `auth.py` wires GitHub OAuth + service-token paths via fastmcp `MultiAuth`.
- `macro_aggregates.py` — shared rollup math used by summary/weight/photo services.

**Auth:** Google OAuth → opaque Bearer session tokens. `/auth/google/start` + `/auth/google/callback` run the handshake, issue a 32-byte URL-safe token, and store `sha256(token)` in the `sessions` table. `SessionAuthMiddleware` validates `Authorization: Bearer <token>` on every non-`/auth/*`/`/health` request and slides the TTL. Allowlist is `ALLOWED_EMAILS` (case-insensitive). `UserKeyGuardrailMiddleware` rejects any `?user_key=` query on protected routes (cutover guardrail; remove next release). Single-user today: `email_to_user_key` returns `LEGACY_USER_KEY`. MCP has two auth paths: GitHub OAuth (`GITHUB_CLIENT_ID/SECRET` + `PUBLIC_BASE_URL`) for interactive clients, and a static service token (`MCP_SERVICE_TOKEN`, min 32 chars) for headless agents — both can run together. `/mcp` is exempt from `SessionAuthMiddleware`; non-local startup refuses to boot unless GitHub OAuth, the service token, or `MCP_ALLOW_UNAUTH=true` is configured. The service token synthesizes a `login=service-account` claim that auto-joins any non-empty `ALLOWED_GITHUB_USERS`.

**Config (`config.py`):** `DATABASE_URL`, `USDA_API_KEY`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `OAUTH_REDIRECT_URI`, `APP_REDIRECT_SCHEME`, `ALLOWED_EMAILS`, `SESSION_TTL_DAYS`, `SESSION_TOKEN_BYTES`, `LEGACY_USER_KEY`, `PORT`, `TIMEZONE`, `APP_ENV`; MCP: `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `ALLOWED_GITHUB_USERS`, `PUBLIC_BASE_URL`, `MCP_SERVICE_TOKEN`, `MCP_ALLOW_UNAUTH`. HTTPS-required for OAuth redirect outside local-mode.

**DB lifecycle:** `db.py` manages a module-level SQLAlchemy async engine. `bootstrap_schema()` runs `schema.sql` idempotently on every startup (`IF NOT EXISTS`). Tables: `daily_target_profile`, `daily_logs`, `custom_foods`, `food_memory`, `meals`, `meal_items`, `food_entries`, `sessions`, `containers`, `progress_photo_tags`, `progress_photos`, `weight_entries`. Alembic available for migrations.

**Multi-user:** all data scoped by `user_key` (today: `LEGACY_USER_KEY`, e.g. `"khash"`). Daily logs use deterministic UUID5 from `(user_key, date)` via `services/log_ids.py` for idempotent upserts.

**Photos:** progress + container photos go through `services/image_processing.py` → JPEG bytes + thumbnail, stored inline in Postgres (no external blob store). Upload size is capped via `PhotoTooLargeError`.

**USDA integration:** `usda.py` wraps FoodData Central. `normalize_food_nutrients()` maps USDA IDs to the internal macro schema (calories=1008, protein=1003, carbs=1005, fat=1004).

**Tests:** unit tests mock the DB pool and USDA client. Integration tests require `TEST_DATABASE_URL` and are marked `pytest.mark.integration`; they truncate tables between tests.

**Stale tree:** `src/nutrition_server/` is an orphaned pre-rename directory (only `__pycache__`, no `.py`). Safe to delete; nothing imports it.
