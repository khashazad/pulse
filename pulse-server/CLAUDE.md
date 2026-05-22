# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install deps
uv sync --extra dev

# Run server
uv run uvicorn diet_tracker_server.app:app --port 8787 --reload

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

**Auth:** Google OAuth → opaque Bearer session tokens. The server runs the full OAuth handshake on `/auth/google/start` + `/auth/google/callback`, issues a 32-byte URL-safe token, and stores `sha256(token)` in the `sessions` table. `SessionAuthMiddleware` validates `Authorization: Bearer <token>` on every non-`/auth/*`/`/health` request and slides the TTL. Allowlist is `ALLOWED_EMAILS` (case-insensitive). `UserKeyGuardrailMiddleware` rejects any `?user_key=` query on protected routes (cutover guardrail; remove next release). Single-user today: `email_to_user_key` returns `LEGACY_USER_KEY`. MCP layer has two auth paths: GitHub OAuth (`GITHUB_CLIENT_ID/SECRET` + `PUBLIC_BASE_URL`) for interactive clients, and a static service token (`MCP_SERVICE_TOKEN`, min 32 chars) for headless agents. Both can run together via fastmcp's `MultiAuth`. `/mcp` is exempt from `SessionAuthMiddleware`, so non-local startup refuses to boot unless GitHub OAuth, the service token, or `MCP_ALLOW_UNAUTH=true` is configured. The service token synthesizes a GitHub-style `login=service-account` claim that `GitHubAllowlistMiddleware` accepts; the claim auto-joins any non-empty `ALLOWED_GITHUB_USERS`.

**Config:** `config.py` loads from env vars (`DATABASE_URL`, `USDA_API_KEY`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `OAUTH_REDIRECT_URI`, `APP_REDIRECT_SCHEME`, `ALLOWED_EMAILS`, `SESSION_TTL_DAYS`, `LEGACY_USER_KEY`, `APP_ENV`).

**DB lifecycle:** `db.py` manages a module-level SQLAlchemy async engine. `bootstrap_schema()` runs `schema.sql` idempotently on every startup (uses `IF NOT EXISTS`). Alembic is available for migrations but schema bootstrap handles the base schema.

**Multi-user:** all data is scoped by `user_key` (today: `LEGACY_USER_KEY`, e.g. `"khash"`). Daily logs use deterministic UUID5 from `(user_key, date)` via `services/log_ids.py` to allow idempotent upserts.

**USDA integration:** `usda.py` wraps FoodData Central API. `normalize_food_nutrients()` maps USDA nutrient IDs to the internal macro schema (calories=1008, protein=1003, carbs=1005, fat=1004).

**Tests:** unit tests mock the DB pool and USDA client. Integration tests require `TEST_DATABASE_URL` and are marked `pytest.mark.integration`; they truncate tables between tests.
