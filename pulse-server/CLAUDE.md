# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install deps
uv sync --extra dev

# Run server
uv run uvicorn nutrition_server.app:app --port 8787 --reload

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

**Auth:** flat shared API key via `X-API-Key` header, configured at startup in `auth.py`. All routers depend on `require_api_key`.

**Config:** `config.py` loads from env vars (`DATABASE_URL`, `USDA_API_KEY`, `API_KEY`). Falls back to `~/.clawdbot/credentials/nutrition-tracker/config.json` for legacy dev credentials.

**DB lifecycle:** `db.py` manages a module-level SQLAlchemy async engine. `bootstrap_schema()` runs `schema.sql` idempotently on every startup (uses `IF NOT EXISTS`). Alembic is available for migrations but schema bootstrap handles the base schema.

**Multi-user:** all data is scoped by `user_key` (default: `"default"`). Daily logs use deterministic UUID5 from `(user_key, date)` via `services/log_ids.py` to allow idempotent upserts.

**USDA integration:** `usda.py` wraps FoodData Central API. `normalize_food_nutrients()` maps USDA nutrient IDs to the internal macro schema (calories=1008, protein=1003, carbs=1005, fat=1004).

**Tests:** unit tests mock the DB pool and USDA client. Integration tests require `TEST_DATABASE_URL` and are marked `pytest.mark.integration`; they truncate tables between tests.
