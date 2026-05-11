# Google OAuth Login — Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace static `X-API-Key` auth with a server-mediated Google OAuth flow that issues opaque session tokens to the iOS client and validates them as Bearer credentials on every subsequent REST call.

**Architecture:** The server owns the entire OAuth handshake (Google client secret stays server-side). On callback success, the server issues a 32-byte random session token (DB stores `sha256(token)` only) and 302s back to a `diettracker://` custom scheme with the token. Every protected REST route now depends on a `require_session` Bearer middleware that looks up the session, slides its TTL, and attaches `request.state.email` / `request.state.user_key` for handlers. A guardrail middleware rejects any non-`/auth/*` request that still carries `?user_key=`. MCP layer keeps its existing GitHub OAuth path; the obsolete `API_KEY` env (and `auth.require_api_key`) are removed.

**Tech Stack:** FastAPI, SQLAlchemy Core (async psycopg3), Alembic, `google-auth` (ID-token JWKS verification), `httpx` (token exchange — already in deps), `pydantic-settings`, `pytest`/`pytest-asyncio`.

**Spec:** `docs/superpowers/specs/2026-05-09-google-oauth-login-server-design.md`

---

## File Structure

**Created:**
- `src/diet_tracker_server/auth/__init__.py` — re-exports
- `src/diet_tracker_server/auth/sessions.py` — token generation, hashing, slide logic (pure functions + repo)
- `src/diet_tracker_server/auth/google.py` — Google authorize URL builder, token-exchange, ID-token verification helper
- `src/diet_tracker_server/auth/middleware.py` — `SessionAuthMiddleware`, `UserKeyGuardrailMiddleware`, `require_session` FastAPI dependency
- `src/diet_tracker_server/repositories/sessions.py` — `SessionsRepository` (insert / lookup / slide / delete)
- `src/diet_tracker_server/routers/auth.py` — `/auth/google/start`, `/auth/google/callback`, `/auth/whoami`, `/auth/logout`
- `alembic/versions/20260509_000001_sessions_table.py` — sessions table migration
- `tests/test_auth_sessions.py` — unit tests for token gen, hashing, slide
- `tests/test_auth_google.py` — unit tests for Google helpers (URL build, token exchange w/ mocked httpx, verify)
- `tests/test_auth_routes.py` — start / callback / whoami / logout route tests with mocked Google
- `tests/test_auth_middleware.py` — Bearer middleware + user_key guardrail tests
- `tests/integration/test_auth_integration.py` — end-to-end sign-in → call → logout against real Postgres

**Modified:**
- `src/diet_tracker_server/auth.py` — DELETE this file (replaced by `auth/` package)
- `src/diet_tracker_server/config.py` — drop `api_key`; add Google + session env vars and `legacy_user_key`
- `src/diet_tracker_server/app.py` — register session + guardrail middleware, mount `/auth` router, drop `auth.configure(settings.api_key)`
- `src/diet_tracker_server/repositories/tables.py` — append `sessions` Table
- `src/diet_tracker_server/repositories/__init__.py` — re-export new repo if other repos are
- `schema.sql` — append idempotent `sessions` table DDL (matches Alembic)
- `src/diet_tracker_server/routers/{entries,logs,summary,targets,custom_foods,food_memory,meals,usda}.py` — replace `Depends(require_api_key)` with `Depends(require_session)`; drop every `user_key: str | None = Query(default=None)` and `effective_user_key = user_key or settings.default_user_key`; pull `user_key` from `request.state.user_key`
- `src/diet_tracker_server/models/{entries,custom_foods,food_memory,meals}.py` — drop the `user_key` request-body field on every *Create/*Request model (response models keep their `user_key` field — comes from DB rows)
- `src/diet_tracker_server/mcp/server.py` — drop the `ApiKeyMiddleware` fallback (require GitHub OAuth or run unauth in local dev — see open question)
- `src/diet_tracker_server/mcp/auth.py` — DELETE `ApiKeyMiddleware` (keep `GitHubAllowlistMiddleware`)
- `tests/test_app.py` — replace `os.environ["API_KEY"]` setup with Google + allowlist envs; rewrite `test_unauthenticated_request_rejected` for Bearer
- `tests/test_mcp_tools.py` — replace any `API_KEY` reference with the new env shape
- `tests/integration/conftest.py` (if present) — same env replacement
- `pyproject.toml` — add `google-auth>=2.30`

**Deleted at end of cutover:**
- `src/diet_tracker_server/auth.py` (single-file form replaced by package)

---

## Task 1: Add `google-auth` dependency

**Files:**
- Modify: `pyproject.toml`

- [ ] **Step 1: Edit `pyproject.toml`**

Add `"google-auth>=2.30"` to `dependencies` (after `fastmcp>=2.7`):

```toml
dependencies = [
    "fastapi>=0.115",
    "uvicorn[standard]>=0.34",
    "psycopg[binary]>=3.2",
    "psycopg-pool>=3.2",
    "sqlalchemy>=2.0",
    "greenlet>=3.0",
    "alembic>=1.16",
    "pydantic-settings>=2.7",
    "httpx>=0.28",
    "fastmcp>=2.7",
    "google-auth>=2.30",
]
```

- [ ] **Step 2: Sync deps**

Run: `uv sync --extra dev`
Expected: lock file updates, `google-auth` installed.

- [ ] **Step 3: Verify import**

Run: `uv run python -c "from google.oauth2 import id_token; from google.auth.transport import requests as g_requests; print('ok')"`
Expected: `ok`

- [ ] **Step 4: Commit**

```bash
git add pyproject.toml uv.lock
git commit -m "chore(deps): add google-auth for ID-token verification"
```

---

## Task 2: Configuration — env vars

**Files:**
- Modify: `src/diet_tracker_server/config.py`
- Test: `tests/test_config.py` (new)

- [ ] **Step 1: Write failing test**

Create `tests/test_config.py`:

```python
from __future__ import annotations

import os
from importlib import reload

import pytest


@pytest.fixture(autouse=True)
def _isolate_env(monkeypatch):
    for k in (
        "API_KEY",
        "GOOGLE_CLIENT_ID",
        "GOOGLE_CLIENT_SECRET",
        "OAUTH_REDIRECT_URI",
        "APP_REDIRECT_SCHEME",
        "ALLOWED_EMAILS",
        "SESSION_TTL_DAYS",
        "SESSION_TOKEN_BYTES",
        "LEGACY_USER_KEY",
    ):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("DATABASE_URL", "postgresql://localhost/test")
    monkeypatch.setenv("USDA_API_KEY", "x")
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "cid")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "secret")
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "https://api.example.com/auth/google/callback")
    monkeypatch.setenv("APP_REDIRECT_SCHEME", "diettracker")
    monkeypatch.setenv("ALLOWED_EMAILS", "khashzd@gmail.com,Other@Example.com")
    monkeypatch.setenv("LEGACY_USER_KEY", "khash")
    yield


def test_settings_has_no_api_key_field():
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert not hasattr(s, "api_key"), "api_key must be removed"


def test_settings_loads_oauth_envs():
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.google_client_id == "cid"
    assert s.google_client_secret == "secret"
    assert s.oauth_redirect_uri == "https://api.example.com/auth/google/callback"
    assert s.app_redirect_scheme == "diettracker"
    assert s.legacy_user_key == "khash"
    assert s.session_ttl_days == 90
    assert s.session_token_bytes == 32


def test_allowed_emails_set_lowercased():
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.allowed_emails_set == {"khashzd@gmail.com", "other@example.com"}


def test_redirect_uri_must_be_https_outside_local(monkeypatch):
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "http://api.example.com/auth/google/callback")
    monkeypatch.setenv("APP_ENV", "prod")
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    with pytest.raises(ValueError, match="must use https"):
        cfg.get_settings()


def test_redirect_uri_http_allowed_for_local(monkeypatch):
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "http://localhost:8787/auth/google/callback")
    monkeypatch.setenv("APP_ENV", "local")
    from diet_tracker_server import config as cfg

    cfg.get_settings.cache_clear()
    s = cfg.get_settings()
    assert s.oauth_redirect_uri.startswith("http://localhost")
```

- [ ] **Step 2: Run test, expect failure**

Run: `uv run pytest tests/test_config.py -v`
Expected: FAILs (current Settings has `api_key`, no Google fields).

- [ ] **Step 3: Update `src/diet_tracker_server/config.py`**

Replace the file with:

```python
from __future__ import annotations

from functools import lru_cache

from pydantic import field_validator, model_validator
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str
    usda_api_key: str

    # Google OAuth (iOS-facing).
    google_client_id: str = ""
    google_client_secret: str = ""
    oauth_redirect_uri: str = ""
    app_redirect_scheme: str = "diettracker"
    allowed_emails: str = ""  # comma-separated
    session_ttl_days: int = 90
    session_token_bytes: int = 32
    legacy_user_key: str = "khash"

    # Existing.
    default_user_key: str = "default"
    port: int = 8787
    timezone: str = "America/Toronto"
    app_env: str = "local"

    # MCP / claude.ai connector OAuth (separate from Google iOS auth).
    github_client_id: str = ""
    github_client_secret: str = ""
    allowed_github_users: str = ""
    public_base_url: str = ""

    model_config = {
        "env_prefix": "",
        "case_sensitive": False,
        "env_file": ".env",
        "env_file_encoding": "utf-8",
        "extra": "ignore",
    }

    @property
    def allowed_emails_set(self) -> set[str]:
        return {e.strip().lower() for e in self.allowed_emails.split(",") if e.strip()}

    @property
    def allowed_github_users_set(self) -> set[str]:
        return {u.strip().lower() for u in self.allowed_github_users.split(",") if u.strip()}

    @property
    def mcp_oauth_enabled(self) -> bool:
        return bool(self.github_client_id and self.github_client_secret and self.public_base_url)

    @model_validator(mode="after")
    def _enforce_https_redirect_outside_local(self) -> "Settings":
        env = (self.app_env or "").lower()
        if env in {"local", "dev", "test"}:
            return self
        if self.oauth_redirect_uri and not self.oauth_redirect_uri.startswith("https://"):
            raise ValueError("OAUTH_REDIRECT_URI must use https in non-local environments")
        return self


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
```

Notes:
- Removed `api_key`.
- Renamed `oauth_enabled` to `mcp_oauth_enabled` (it was specifically about the MCP/GitHub flow); update its one caller in `mcp/server.py` in Task 14.

- [ ] **Step 4: Run tests, expect pass**

Run: `uv run pytest tests/test_config.py -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/diet_tracker_server/config.py tests/test_config.py
git commit -m "feat(config): add Google OAuth + session envs, drop API_KEY"
```

---

## Task 3: Sessions table — schema + Alembic migration + Core table

**Files:**
- Create: `alembic/versions/20260509_000001_sessions_table.py`
- Modify: `schema.sql`, `src/diet_tracker_server/repositories/tables.py`
- Test: `tests/test_db_split.py` (extend)

- [ ] **Step 1: Write failing test (schema split)**

Append to `tests/test_db_split.py`:

```python
def test_schema_sql_contains_sessions_table():
    from pathlib import Path
    sql = Path("schema.sql").read_text()
    assert "create table if not exists sessions" in sql.lower()
    assert "token_hash" in sql.lower()
```

(If `tests/test_db_split.py` already tests SQL splitting, add this as a new function in the same file.)

- [ ] **Step 2: Run test, expect fail**

Run: `uv run pytest tests/test_db_split.py::test_schema_sql_contains_sessions_table -v`
Expected: FAIL.

- [ ] **Step 3: Append to `schema.sql`**

```sql
create table if not exists sessions (
  token_hash    bytea primary key,
  email         text not null,
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz not null default now(),
  expires_at    timestamptz not null
);
create index if not exists idx_sessions_email on sessions (email);
create index if not exists idx_sessions_expires_at on sessions (expires_at);
```

- [ ] **Step 4: Append `sessions` Table to `repositories/tables.py`**

```python
from sqlalchemy import LargeBinary  # add to existing imports

sessions = Table(
    "sessions",
    metadata,
    Column("token_hash", LargeBinary, primary_key=True),
    Column("email", Text, nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("last_used_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("expires_at", DateTime(timezone=True), nullable=False),
    Index("idx_sessions_email", "email"),
    Index("idx_sessions_expires_at", "expires_at"),
)
```

- [ ] **Step 5: Create `alembic/versions/20260509_000001_sessions_table.py`**

```python
"""Add sessions table for Google OAuth bearer auth.

Revision ID: 20260509_000001
Revises: 20260506_000001
Create Date: 2026-05-09T00:00:00Z
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260509_000001"
down_revision = "20260506_000001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "sessions",
        sa.Column("token_hash", sa.LargeBinary(), nullable=False),
        sa.Column("email", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("token_hash"),
    )
    op.create_index("idx_sessions_email", "sessions", ["email"], unique=False)
    op.create_index("idx_sessions_expires_at", "sessions", ["expires_at"], unique=False)


def downgrade() -> None:
    op.drop_index("idx_sessions_expires_at", table_name="sessions")
    op.drop_index("idx_sessions_email", table_name="sessions")
    op.drop_table("sessions")
```

- [ ] **Step 6: Run schema test, expect pass**

Run: `uv run pytest tests/test_db_split.py::test_schema_sql_contains_sessions_table -v`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add schema.sql src/diet_tracker_server/repositories/tables.py alembic/versions/20260509_000001_sessions_table.py tests/test_db_split.py
git commit -m "feat(db): add sessions table (Alembic + schema.sql + Core table)"
```

---

## Task 4: Sessions repository

**Files:**
- Create: `src/diet_tracker_server/repositories/sessions.py`
- Test: `tests/integration/test_sessions_repository.py`

- [ ] **Step 1: Write failing integration test**

Create `tests/integration/test_sessions_repository.py`:

```python
from __future__ import annotations

import hashlib
import os
from datetime import datetime, timedelta, timezone

import pytest

pytestmark = pytest.mark.integration


@pytest.fixture
async def session():
    if not os.environ.get("TEST_DATABASE_URL"):
        pytest.skip("TEST_DATABASE_URL not set")
    from diet_tracker_server import db

    await db.init_pool(os.environ["TEST_DATABASE_URL"])
    await db.bootstrap_schema()
    async with db.get_session() as s:
        await s.execute(__import__("sqlalchemy").text("truncate sessions"))
        await s.commit()
        yield s
    await db.close_pool()


def _hash(token: str) -> bytes:
    return hashlib.sha256(token.encode()).digest()


async def test_create_and_lookup(session):
    from diet_tracker_server.repositories.sessions import SessionsRepository

    repo = SessionsRepository(session)
    now = datetime.now(timezone.utc)
    expires = now + timedelta(days=7)
    await repo.create(token_hash=_hash("tok"), email="user@example.com", now=now, expires_at=expires)
    await session.commit()

    row = await repo.get(_hash("tok"))
    assert row is not None
    assert row["email"] == "user@example.com"
    assert row["expires_at"] == expires


async def test_slide_extends_expiry(session):
    from diet_tracker_server.repositories.sessions import SessionsRepository

    repo = SessionsRepository(session)
    now = datetime.now(timezone.utc)
    h = _hash("tok2")
    await repo.create(token_hash=h, email="u@example.com", now=now, expires_at=now + timedelta(days=1))
    await session.commit()

    new_now = now + timedelta(hours=1)
    new_expires = new_now + timedelta(days=7)
    updated = await repo.slide(token_hash=h, now=new_now, new_expires_at=new_expires)
    await session.commit()
    assert updated == 1

    row = await repo.get(h)
    assert row["last_used_at"] == new_now
    assert row["expires_at"] == new_expires


async def test_delete_returns_count(session):
    from diet_tracker_server.repositories.sessions import SessionsRepository

    repo = SessionsRepository(session)
    now = datetime.now(timezone.utc)
    h = _hash("tok3")
    await repo.create(token_hash=h, email="u@example.com", now=now, expires_at=now + timedelta(days=1))
    await session.commit()

    count = await repo.delete(h)
    await session.commit()
    assert count == 1

    again = await repo.delete(h)
    await session.commit()
    assert again == 0
```

- [ ] **Step 2: Run test (will fail with ImportError)**

Run: `TEST_DATABASE_URL=postgresql://localhost/diet_test uv run pytest tests/integration/test_sessions_repository.py -v -m integration`
Expected: ImportError (`SessionsRepository` not defined).

- [ ] **Step 3: Implement `src/diet_tracker_server/repositories/sessions.py`**

```python
from __future__ import annotations

from datetime import datetime
from typing import Any

from sqlalchemy import delete, insert, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from diet_tracker_server.repositories.tables import sessions


class SessionsRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def create(
        self,
        *,
        token_hash: bytes,
        email: str,
        now: datetime,
        expires_at: datetime,
    ) -> None:
        await self._session.execute(
            insert(sessions).values(
                token_hash=token_hash,
                email=email,
                created_at=now,
                last_used_at=now,
                expires_at=expires_at,
            )
        )

    async def get(self, token_hash: bytes) -> dict[str, Any] | None:
        result = await self._session.execute(
            select(sessions).where(sessions.c.token_hash == token_hash)
        )
        row = result.mappings().first()
        return dict(row) if row else None

    async def slide(
        self,
        *,
        token_hash: bytes,
        now: datetime,
        new_expires_at: datetime,
    ) -> int:
        result = await self._session.execute(
            update(sessions)
            .where(sessions.c.token_hash == token_hash)
            .values(last_used_at=now, expires_at=new_expires_at)
        )
        return result.rowcount or 0

    async def delete(self, token_hash: bytes) -> int:
        result = await self._session.execute(
            delete(sessions).where(sessions.c.token_hash == token_hash)
        )
        return result.rowcount or 0
```

- [ ] **Step 4: Run test, expect pass**

Run: `TEST_DATABASE_URL=postgresql://localhost/diet_test uv run pytest tests/integration/test_sessions_repository.py -v -m integration`
Expected: PASS (or skipped if no `TEST_DATABASE_URL`).

- [ ] **Step 5: Commit**

```bash
git add src/diet_tracker_server/repositories/sessions.py tests/integration/test_sessions_repository.py
git commit -m "feat(sessions): repository for create/get/slide/delete"
```

---

## Task 5: Auth helpers — token generation & hashing

**Files:**
- Create: `src/diet_tracker_server/auth/__init__.py`, `src/diet_tracker_server/auth/sessions.py`
- Test: `tests/test_auth_sessions.py`

NOTE: When creating `src/diet_tracker_server/auth/__init__.py`, the existing `src/diet_tracker_server/auth.py` module-file conflicts with the package. Move the file out of the way before creating the package: `git rm src/diet_tracker_server/auth.py`. Re-export `require_session` from the package `__init__.py` so deeper imports stay short.

- [ ] **Step 1: Remove old `auth.py`**

```bash
git rm src/diet_tracker_server/auth.py
```

- [ ] **Step 2: Write failing test**

Create `tests/test_auth_sessions.py`:

```python
from __future__ import annotations

import hashlib

from diet_tracker_server.auth.sessions import generate_token, hash_token, email_to_user_key


def test_generate_token_url_safe_and_long_enough():
    tok = generate_token(num_bytes=32)
    assert isinstance(tok, str)
    # base64url without padding: 32 bytes -> 43 chars
    assert len(tok) == 43
    assert all(c.isalnum() or c in "-_" for c in tok)


def test_generate_token_unique():
    a = generate_token(num_bytes=32)
    b = generate_token(num_bytes=32)
    assert a != b


def test_hash_token_is_sha256_of_utf8():
    tok = "hello"
    assert hash_token(tok) == hashlib.sha256(b"hello").digest()


def test_email_to_user_key_returns_legacy_value(monkeypatch):
    monkeypatch.setenv("LEGACY_USER_KEY", "khash")
    monkeypatch.setenv("DATABASE_URL", "postgresql://localhost/test")
    monkeypatch.setenv("USDA_API_KEY", "x")
    monkeypatch.setenv("ALLOWED_EMAILS", "khashzd@gmail.com")
    from diet_tracker_server.config import get_settings

    get_settings.cache_clear()
    assert email_to_user_key("khashzd@gmail.com") == "khash"
    assert email_to_user_key("other@example.com") == "khash"  # single-user today
```

- [ ] **Step 3: Run test, expect fail**

Run: `uv run pytest tests/test_auth_sessions.py -v`
Expected: ImportError.

- [ ] **Step 4: Create `src/diet_tracker_server/auth/__init__.py`**

```python
from diet_tracker_server.auth.middleware import require_session  # re-export for routers

__all__ = ["require_session"]
```

(Note: `require_session` is created in Task 7. For Task 5 alone the `__init__.py` may temporarily have an empty body; populate it after Task 7.)

For now in this task, write just:

```python
# Populated after middleware lands; see Task 7.
```

- [ ] **Step 5: Create `src/diet_tracker_server/auth/sessions.py`**

```python
from __future__ import annotations

import base64
import hashlib
import secrets

from diet_tracker_server.config import get_settings


def generate_token(*, num_bytes: int) -> str:
    raw = secrets.token_bytes(num_bytes)
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def hash_token(token: str) -> bytes:
    return hashlib.sha256(token.encode("utf-8")).digest()


def email_to_user_key(email: str) -> str:
    # Single-user-today: every allowed email maps to the legacy user_key.
    # Future multi-user: this becomes a real users-table lookup.
    del email
    return get_settings().legacy_user_key
```

- [ ] **Step 6: Run test, expect pass**

Run: `uv run pytest tests/test_auth_sessions.py -v`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/diet_tracker_server/auth/__init__.py src/diet_tracker_server/auth/sessions.py tests/test_auth_sessions.py
git rm --cached src/diet_tracker_server/auth.py 2>/dev/null || true
git commit -m "feat(auth): token gen + hash + email_to_user_key helper"
```

---

## Task 6: Google OAuth helpers — URL build, token exchange, ID-token verify

**Files:**
- Create: `src/diet_tracker_server/auth/google.py`
- Test: `tests/test_auth_google.py`

- [ ] **Step 1: Write failing tests**

Create `tests/test_auth_google.py`:

```python
from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "postgresql://localhost/test")
    monkeypatch.setenv("USDA_API_KEY", "x")
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "cid.apps.googleusercontent.com")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "secret")
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "https://api.example.com/auth/google/callback")
    monkeypatch.setenv("APP_REDIRECT_SCHEME", "diettracker")
    monkeypatch.setenv("ALLOWED_EMAILS", "khashzd@gmail.com")
    monkeypatch.setenv("LEGACY_USER_KEY", "khash")
    monkeypatch.setenv("APP_ENV", "local")
    from diet_tracker_server.config import get_settings

    get_settings.cache_clear()


def test_build_authorize_url_includes_required_params():
    from diet_tracker_server.auth.google import build_authorize_url

    url = build_authorize_url(state="abc123")
    assert url.startswith("https://accounts.google.com/o/oauth2/v2/auth?")
    assert "client_id=cid.apps.googleusercontent.com" in url
    assert "redirect_uri=https%3A%2F%2Fapi.example.com%2Fauth%2Fgoogle%2Fcallback" in url
    assert "response_type=code" in url
    assert "scope=openid+email+profile" in url or "scope=openid%20email%20profile" in url
    assert "state=abc123" in url
    assert "prompt=select_account" in url
    assert "access_type=online" in url


@pytest.mark.asyncio
async def test_exchange_code_for_id_token_calls_google():
    from diet_tracker_server.auth import google as g

    mock_client = AsyncMock()
    mock_response = AsyncMock()
    mock_response.status_code = 200
    mock_response.json = lambda: {"id_token": "fake.jwt.value"}
    mock_response.raise_for_status = lambda: None
    mock_client.__aenter__.return_value = mock_client
    mock_client.__aexit__.return_value = None
    mock_client.post.return_value = mock_response

    with patch("diet_tracker_server.auth.google.httpx.AsyncClient", return_value=mock_client):
        id_token = await g.exchange_code_for_id_token(code="auth_code")

    assert id_token == "fake.jwt.value"
    args, kwargs = mock_client.post.call_args
    assert args[0] == "https://oauth2.googleapis.com/token"
    body = kwargs["data"]
    assert body["code"] == "auth_code"
    assert body["client_id"] == "cid.apps.googleusercontent.com"
    assert body["client_secret"] == "secret"
    assert body["redirect_uri"] == "https://api.example.com/auth/google/callback"
    assert body["grant_type"] == "authorization_code"


@pytest.mark.asyncio
async def test_exchange_code_raises_on_non_2xx():
    from diet_tracker_server.auth import google as g
    import httpx

    mock_client = AsyncMock()
    mock_response = AsyncMock()
    mock_response.status_code = 400
    def _raise():
        raise httpx.HTTPStatusError("bad", request=None, response=None)
    mock_response.raise_for_status = _raise
    mock_client.__aenter__.return_value = mock_client
    mock_client.__aexit__.return_value = None
    mock_client.post.return_value = mock_response

    with patch("diet_tracker_server.auth.google.httpx.AsyncClient", return_value=mock_client):
        with pytest.raises(g.GoogleAuthError):
            await g.exchange_code_for_id_token(code="bad")


def test_verify_id_token_returns_email_and_sub():
    from diet_tracker_server.auth import google as g

    payload = {"email": "Khashzd@Gmail.com", "sub": "1234567890", "aud": "cid.apps.googleusercontent.com"}
    with patch("diet_tracker_server.auth.google.id_token.verify_oauth2_token", return_value=payload):
        email, sub = g.verify_id_token("jwt-here")
    assert email == "khashzd@gmail.com"  # lowercased
    assert sub == "1234567890"


def test_verify_id_token_raises_on_invalid():
    from diet_tracker_server.auth import google as g

    with patch(
        "diet_tracker_server.auth.google.id_token.verify_oauth2_token",
        side_effect=ValueError("bad signature"),
    ):
        with pytest.raises(g.GoogleAuthError):
            g.verify_id_token("jwt-here")
```

- [ ] **Step 2: Run, expect fail**

Run: `uv run pytest tests/test_auth_google.py -v`
Expected: ImportError.

- [ ] **Step 3: Implement `src/diet_tracker_server/auth/google.py`**

```python
from __future__ import annotations

from urllib.parse import urlencode

import httpx
from google.auth.transport import requests as google_requests
from google.oauth2 import id_token

from diet_tracker_server.config import get_settings


GOOGLE_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"


class GoogleAuthError(Exception):
    """Raised when Google OAuth handshake fails for any reason."""


def build_authorize_url(*, state: str) -> str:
    settings = get_settings()
    params = {
        "client_id": settings.google_client_id,
        "redirect_uri": settings.oauth_redirect_uri,
        "response_type": "code",
        "scope": "openid email profile",
        "state": state,
        "prompt": "select_account",
        "access_type": "online",
    }
    return f"{GOOGLE_AUTHORIZE_URL}?{urlencode(params)}"


async def exchange_code_for_id_token(*, code: str) -> str:
    settings = get_settings()
    body = {
        "code": code,
        "client_id": settings.google_client_id,
        "client_secret": settings.google_client_secret,
        "redirect_uri": settings.oauth_redirect_uri,
        "grant_type": "authorization_code",
    }
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(GOOGLE_TOKEN_URL, data=body)
            resp.raise_for_status()
            data = resp.json()
    except httpx.HTTPError as exc:
        raise GoogleAuthError("Google token endpoint failed") from exc

    token = data.get("id_token")
    if not token:
        raise GoogleAuthError("Google response missing id_token")
    return token


def verify_id_token(jwt_str: str) -> tuple[str, str]:
    """Returns (email_lower, sub). Raises GoogleAuthError on any verification failure."""
    settings = get_settings()
    try:
        payload = id_token.verify_oauth2_token(
            jwt_str,
            google_requests.Request(),
            settings.google_client_id,
        )
    except ValueError as exc:
        raise GoogleAuthError(f"id_token verification failed: {exc}") from exc

    email = payload.get("email")
    sub = payload.get("sub")
    if not email or not sub:
        raise GoogleAuthError("id_token missing email/sub")
    return email.strip().lower(), sub
```

- [ ] **Step 4: Run, expect pass**

Run: `uv run pytest tests/test_auth_google.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/diet_tracker_server/auth/google.py tests/test_auth_google.py
git commit -m "feat(auth): Google authorize URL + token exchange + id_token verify"
```

---

## Task 7: Session middleware + `require_session` dependency

**Files:**
- Create: `src/diet_tracker_server/auth/middleware.py`
- Modify: `src/diet_tracker_server/auth/__init__.py`
- Test: `tests/test_auth_middleware.py`

- [ ] **Step 1: Write failing test**

Create `tests/test_auth_middleware.py`:

```python
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, patch

import pytest
from fastapi import FastAPI, Request
from fastapi.testclient import TestClient


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "postgresql://localhost/test")
    monkeypatch.setenv("USDA_API_KEY", "x")
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "cid")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "secret")
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "https://api.example.com/auth/google/callback")
    monkeypatch.setenv("APP_REDIRECT_SCHEME", "diettracker")
    monkeypatch.setenv("ALLOWED_EMAILS", "khashzd@gmail.com")
    monkeypatch.setenv("LEGACY_USER_KEY", "khash")
    monkeypatch.setenv("APP_ENV", "local")
    monkeypatch.setenv("SESSION_TTL_DAYS", "7")
    from diet_tracker_server.config import get_settings
    get_settings.cache_clear()


def _build_app():
    from diet_tracker_server.auth.middleware import (
        SessionAuthMiddleware,
        UserKeyGuardrailMiddleware,
        require_session,
    )
    from fastapi import Depends

    app = FastAPI()
    app.add_middleware(SessionAuthMiddleware)
    app.add_middleware(UserKeyGuardrailMiddleware)

    @app.get("/health")
    async def health():
        return {"status": "ok"}

    @app.get("/me")
    async def me(request: Request, _ = Depends(require_session)):
        return {"email": request.state.email, "user_key": request.state.user_key}

    return app


def test_health_unauthenticated_passes_through():
    app = _build_app()
    with TestClient(app) as c:
        r = c.get("/health")
        assert r.status_code == 200


def test_protected_missing_bearer_returns_401():
    app = _build_app()
    with TestClient(app) as c:
        r = c.get("/me")
        assert r.status_code == 401


def test_protected_invalid_bearer_format_returns_401():
    app = _build_app()
    with TestClient(app) as c:
        r = c.get("/me", headers={"Authorization": "Token abc"})
        assert r.status_code == 401


def test_protected_unknown_session_returns_401():
    app = _build_app()
    fake_repo = AsyncMock()
    fake_repo.get.return_value = None
    fake_session_ctx = AsyncMock()
    fake_session_ctx.__aenter__.return_value = AsyncMock()
    fake_session_ctx.__aexit__.return_value = None

    with patch("diet_tracker_server.auth.middleware.get_session", return_value=fake_session_ctx), \
         patch("diet_tracker_server.auth.middleware.SessionsRepository", return_value=fake_repo):
        with TestClient(app := _build_app()) as c:
            r = c.get("/me", headers={"Authorization": "Bearer unknown"})
            assert r.status_code == 401


def test_protected_expired_session_returns_401_and_deletes():
    app = _build_app()
    past = datetime.now(timezone.utc) - timedelta(days=1)
    fake_repo = AsyncMock()
    fake_repo.get.return_value = {"email": "u@e.com", "expires_at": past}
    fake_repo.delete.return_value = 1

    fake_session = AsyncMock()
    fake_session_ctx = AsyncMock()
    fake_session_ctx.__aenter__.return_value = fake_session
    fake_session_ctx.__aexit__.return_value = None

    with patch("diet_tracker_server.auth.middleware.get_session", return_value=fake_session_ctx), \
         patch("diet_tracker_server.auth.middleware.SessionsRepository", return_value=fake_repo):
        with TestClient(app) as c:
            r = c.get("/me", headers={"Authorization": "Bearer tok"})
            assert r.status_code == 401
            fake_repo.delete.assert_awaited_once()


def test_protected_happy_path_slides_and_attaches_state():
    app = _build_app()
    future = datetime.now(timezone.utc) + timedelta(days=7)
    fake_repo = AsyncMock()
    fake_repo.get.return_value = {"email": "khashzd@gmail.com", "expires_at": future}
    fake_repo.slide.return_value = 1

    fake_session = AsyncMock()
    fake_session_ctx = AsyncMock()
    fake_session_ctx.__aenter__.return_value = fake_session
    fake_session_ctx.__aexit__.return_value = None

    with patch("diet_tracker_server.auth.middleware.get_session", return_value=fake_session_ctx), \
         patch("diet_tracker_server.auth.middleware.SessionsRepository", return_value=fake_repo):
        with TestClient(app) as c:
            r = c.get("/me", headers={"Authorization": "Bearer tok"})
            assert r.status_code == 200
            assert r.json() == {"email": "khashzd@gmail.com", "user_key": "khash"}
            fake_repo.slide.assert_awaited_once()


def test_user_key_query_guardrail_returns_400_on_protected_route():
    app = _build_app()
    future = datetime.now(timezone.utc) + timedelta(days=7)
    fake_repo = AsyncMock()
    fake_repo.get.return_value = {"email": "u@e.com", "expires_at": future}
    fake_repo.slide.return_value = 1
    fake_session = AsyncMock()
    fake_session_ctx = AsyncMock()
    fake_session_ctx.__aenter__.return_value = fake_session
    fake_session_ctx.__aexit__.return_value = None

    with patch("diet_tracker_server.auth.middleware.get_session", return_value=fake_session_ctx), \
         patch("diet_tracker_server.auth.middleware.SessionsRepository", return_value=fake_repo):
        with TestClient(app) as c:
            r = c.get("/me?user_key=foo", headers={"Authorization": "Bearer tok"})
            assert r.status_code == 400
            assert "user_key" in r.json().get("error", "")


def test_user_key_query_guardrail_skips_auth_routes():
    app = _build_app()
    with TestClient(app) as c:
        # auth routes don't exist on this dummy app — but the guardrail must let them pass
        # without 400. This route is unauthed and missing, so we expect 404 (not 400).
        r = c.get("/auth/google/start?user_key=foo")
        assert r.status_code != 400
```

- [ ] **Step 2: Run, expect fail**

Run: `uv run pytest tests/test_auth_middleware.py -v`
Expected: ImportError.

- [ ] **Step 3: Implement `src/diet_tracker_server/auth/middleware.py`**

```python
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi import Request
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse

from diet_tracker_server.auth.sessions import email_to_user_key, hash_token
from diet_tracker_server.config import get_settings
from diet_tracker_server.db import get_session
from diet_tracker_server.repositories.sessions import SessionsRepository


PUBLIC_PATHS = {"/health", "/auth/google/start", "/auth/google/callback"}


def _is_public(path: str) -> bool:
    if path in PUBLIC_PATHS:
        return True
    # Anything under /auth/* is exempt from the user_key guardrail; auth itself is
    # handled per-route via require_session.
    return path.startswith("/auth/")


class UserKeyGuardrailMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if not _is_public(request.url.path) and "user_key" in request.query_params:
            return JSONResponse(
                status_code=400,
                content={"error": "user_key query param is no longer accepted"},
            )
        return await call_next(request)


class SessionAuthMiddleware(BaseHTTPMiddleware):
    """Validates Bearer tokens and slides session expiry. Sets request.state.email and user_key."""

    async def dispatch(self, request: Request, call_next):
        # Skip auth for public paths; auth routes self-handle via require_session where needed.
        if _is_public(request.url.path):
            return await call_next(request)

        header = request.headers.get("authorization", "")
        if not header.lower().startswith("bearer "):
            return JSONResponse(status_code=401, content={"error": "Bearer token required"})
        token = header[7:].strip()
        if not token:
            return JSONResponse(status_code=401, content={"error": "Bearer token required"})

        token_hash = hash_token(token)
        settings = get_settings()
        now = datetime.now(timezone.utc)
        new_expires = now + timedelta(days=settings.session_ttl_days)

        async with get_session() as db_session:
            repo = SessionsRepository(db_session)
            row = await repo.get(token_hash)
            if row is None:
                return JSONResponse(status_code=401, content={"error": "Invalid session"})
            if row["expires_at"] <= now:
                await repo.delete(token_hash)
                await db_session.commit()
                return JSONResponse(status_code=401, content={"error": "Session expired"})
            await repo.slide(token_hash=token_hash, now=now, new_expires_at=new_expires)
            await db_session.commit()

        request.state.email = row["email"]
        request.state.user_key = email_to_user_key(row["email"])
        request.state.session_expires_at = new_expires
        return await call_next(request)


async def require_session(request: Request) -> None:
    """No-op dependency: middleware has already validated the session and populated state.

    Routes that depend on this declare 'this route is auth-required' for documentation and so
    that auth-public routes don't accidentally reach handler code without state being set.
    """
    if not getattr(request.state, "email", None):
        from fastapi import HTTPException
        raise HTTPException(status_code=401, detail="Authentication required")
    return None
```

- [ ] **Step 4: Update `src/diet_tracker_server/auth/__init__.py`**

```python
from diet_tracker_server.auth.middleware import (
    SessionAuthMiddleware,
    UserKeyGuardrailMiddleware,
    require_session,
)

__all__ = [
    "SessionAuthMiddleware",
    "UserKeyGuardrailMiddleware",
    "require_session",
]
```

- [ ] **Step 5: Run, expect pass**

Run: `uv run pytest tests/test_auth_middleware.py -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/diet_tracker_server/auth/middleware.py src/diet_tracker_server/auth/__init__.py tests/test_auth_middleware.py
git commit -m "feat(auth): SessionAuthMiddleware + user_key guardrail + require_session"
```

---

## Task 8: Auth router — `/auth/google/start`

**Files:**
- Create: `src/diet_tracker_server/routers/auth.py`
- Test: `tests/test_auth_routes.py`

- [ ] **Step 1: Write failing test**

Create `tests/test_auth_routes.py`:

```python
from __future__ import annotations

import os
from unittest.mock import AsyncMock, patch
from urllib.parse import parse_qs, urlparse

import pytest
from fastapi.testclient import TestClient


os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "x")
os.environ.setdefault("GOOGLE_CLIENT_ID", "cid.apps.googleusercontent.com")
os.environ.setdefault("GOOGLE_CLIENT_SECRET", "secret")
os.environ.setdefault("OAUTH_REDIRECT_URI", "https://api.example.com/auth/google/callback")
os.environ.setdefault("APP_REDIRECT_SCHEME", "diettracker")
os.environ.setdefault("ALLOWED_EMAILS", "khashzd@gmail.com")
os.environ.setdefault("LEGACY_USER_KEY", "khash")
os.environ.setdefault("APP_ENV", "local")
os.environ.setdefault("SESSION_TTL_DAYS", "7")


@pytest.fixture
def client():
    with patch("diet_tracker_server.db.init_pool", new_callable=AsyncMock), \
         patch("diet_tracker_server.db.bootstrap_schema", new_callable=AsyncMock), \
         patch("diet_tracker_server.db.close_pool", new_callable=AsyncMock), \
         patch("diet_tracker_server.usda.USDAClient") as mock_usda:
        mock_usda.return_value.close = AsyncMock()
        from diet_tracker_server.config import get_settings
        get_settings.cache_clear()
        from diet_tracker_server.app import app
        with TestClient(app) as c:
            yield c


def test_start_redirects_to_google_with_state_cookie(client):
    r = client.get("/auth/google/start", follow_redirects=False)
    assert r.status_code == 302
    location = r.headers["location"]
    assert location.startswith("https://accounts.google.com/o/oauth2/v2/auth?")
    qs = parse_qs(urlparse(location).query)
    assert qs["client_id"] == ["cid.apps.googleusercontent.com"]
    assert qs["redirect_uri"] == ["https://api.example.com/auth/google/callback"]
    assert qs["response_type"] == ["code"]
    assert qs["state"][0]
    # state cookie must be set, scoped, HttpOnly
    set_cookie = r.headers.get("set-cookie", "")
    assert "oauth_state=" in set_cookie
    assert "HttpOnly" in set_cookie
    assert "Path=/auth/google" in set_cookie
```

- [ ] **Step 2: Run, expect fail**

Run: `uv run pytest tests/test_auth_routes.py::test_start_redirects_to_google_with_state_cookie -v`
Expected: 404 (route not registered).

- [ ] **Step 3: Implement `src/diet_tracker_server/routers/auth.py`**

```python
from __future__ import annotations

import secrets

from fastapi import APIRouter, Request
from fastapi.responses import RedirectResponse

from diet_tracker_server.auth.google import build_authorize_url
from diet_tracker_server.config import get_settings


router = APIRouter(prefix="/auth")


STATE_COOKIE_NAME = "oauth_state"
STATE_COOKIE_PATH = "/auth/google"
STATE_COOKIE_MAX_AGE = 600  # 10 minutes


def _is_secure_request(request: Request) -> bool:
    return request.url.scheme == "https" or request.headers.get("x-forwarded-proto") == "https"


@router.get("/google/start")
async def google_start(request: Request) -> RedirectResponse:
    state = secrets.token_urlsafe(32)
    location = build_authorize_url(state=state)
    response = RedirectResponse(url=location, status_code=302)
    response.set_cookie(
        key=STATE_COOKIE_NAME,
        value=state,
        max_age=STATE_COOKIE_MAX_AGE,
        path=STATE_COOKIE_PATH,
        secure=_is_secure_request(request),
        httponly=True,
        samesite="lax",
    )
    return response
```

- [ ] **Step 4: Wire router into `app.py` (minimal — just include for this task)**

In `src/diet_tracker_server/app.py`, after the existing `app.include_router(...)` calls add:

```python
from diet_tracker_server.routers import auth as auth_router
app.include_router(auth_router.router)
```

- [ ] **Step 5: Run, expect pass**

Run: `uv run pytest tests/test_auth_routes.py::test_start_redirects_to_google_with_state_cookie -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/diet_tracker_server/routers/auth.py src/diet_tracker_server/app.py tests/test_auth_routes.py
git commit -m "feat(auth): GET /auth/google/start with signed state cookie"
```

---

## Task 9: Auth router — `/auth/google/callback`

**Files:**
- Modify: `src/diet_tracker_server/routers/auth.py`
- Modify: `tests/test_auth_routes.py`

- [ ] **Step 1: Add failing tests for callback paths**

Append to `tests/test_auth_routes.py`:

```python
from datetime import datetime, timezone


@pytest.fixture
def _patch_db_repo():
    """Patch SessionsRepository so create() succeeds without a real DB."""
    fake_repo = AsyncMock()
    fake_repo.create.return_value = None
    fake_session = AsyncMock()
    fake_session_ctx = AsyncMock()
    fake_session_ctx.__aenter__.return_value = fake_session
    fake_session_ctx.__aexit__.return_value = None
    with patch("diet_tracker_server.routers.auth.get_session", return_value=fake_session_ctx), \
         patch("diet_tracker_server.routers.auth.SessionsRepository", return_value=fake_repo):
        yield fake_repo


def test_callback_google_denial_redirects_with_access_denied(client):
    r = client.get(
        "/auth/google/callback",
        params={"error": "access_denied"},
        follow_redirects=False,
    )
    assert r.status_code == 302
    assert r.headers["location"] == "diettracker://auth?error=access_denied"


def test_callback_missing_state_cookie_redirects_invalid_state(client):
    r = client.get(
        "/auth/google/callback",
        params={"code": "x", "state": "abc"},
        follow_redirects=False,
    )
    assert r.status_code == 302
    assert "error=invalid_state" in r.headers["location"]


def test_callback_state_mismatch_redirects_invalid_state(client):
    client.cookies.set("oauth_state", "real_state", path="/auth/google")
    r = client.get(
        "/auth/google/callback",
        params={"code": "x", "state": "wrong"},
        follow_redirects=False,
    )
    assert r.status_code == 302
    assert "error=invalid_state" in r.headers["location"]


def test_callback_disallowed_email_redirects_not_allowed(client, _patch_db_repo):
    client.cookies.set("oauth_state", "s", path="/auth/google")
    with patch(
        "diet_tracker_server.routers.auth.exchange_code_for_id_token",
        new_callable=AsyncMock, return_value="jwt",
    ), patch(
        "diet_tracker_server.routers.auth.verify_id_token",
        return_value=("nobody@gmail.com", "sub"),
    ):
        r = client.get(
            "/auth/google/callback",
            params={"code": "x", "state": "s"},
            follow_redirects=False,
        )
    assert r.status_code == 302
    assert "error=not_allowed" in r.headers["location"]
    _patch_db_repo.create.assert_not_called()


def test_callback_happy_path_creates_session_and_redirects_with_token(client, _patch_db_repo):
    client.cookies.set("oauth_state", "s", path="/auth/google")
    with patch(
        "diet_tracker_server.routers.auth.exchange_code_for_id_token",
        new_callable=AsyncMock, return_value="jwt",
    ), patch(
        "diet_tracker_server.routers.auth.verify_id_token",
        return_value=("khashzd@gmail.com", "sub"),
    ):
        r = client.get(
            "/auth/google/callback",
            params={"code": "x", "state": "s"},
            follow_redirects=False,
        )
    assert r.status_code == 302
    loc = r.headers["location"]
    assert loc.startswith("diettracker://auth?")
    assert "token=" in loc
    assert "email=khashzd%40gmail.com" in loc
    _patch_db_repo.create.assert_awaited_once()


def test_callback_token_exchange_failure_redirects_server_error(client, _patch_db_repo):
    from diet_tracker_server.auth.google import GoogleAuthError
    client.cookies.set("oauth_state", "s", path="/auth/google")
    with patch(
        "diet_tracker_server.routers.auth.exchange_code_for_id_token",
        new_callable=AsyncMock, side_effect=GoogleAuthError("boom"),
    ):
        r = client.get(
            "/auth/google/callback",
            params={"code": "x", "state": "s"},
            follow_redirects=False,
        )
    assert r.status_code == 302
    assert "error=server_error" in r.headers["location"]
```

- [ ] **Step 2: Run, expect fail**

Run: `uv run pytest tests/test_auth_routes.py -v`
Expected: callback tests fail (route 404).

- [ ] **Step 3: Append the callback handler to `src/diet_tracker_server/routers/auth.py`**

Imports to add at top:

```python
import logging
from datetime import datetime, timedelta, timezone
from urllib.parse import quote

from fastapi import Cookie

from diet_tracker_server.auth.google import (
    GoogleAuthError,
    exchange_code_for_id_token,
    verify_id_token,
)
from diet_tracker_server.auth.sessions import generate_token, hash_token
from diet_tracker_server.db import get_session
from diet_tracker_server.repositories.sessions import SessionsRepository

logger = logging.getLogger(__name__)
```

Helper:

```python
def _app_redirect(*, error: str | None = None, token: str | None = None, email: str | None = None) -> RedirectResponse:
    settings = get_settings()
    base = f"{settings.app_redirect_scheme}://auth"
    if error is not None:
        location = f"{base}?error={quote(error)}"
    else:
        assert token is not None and email is not None
        location = f"{base}?token={quote(token, safe='')}&email={quote(email, safe='')}"
    response = RedirectResponse(url=location, status_code=302)
    response.delete_cookie(STATE_COOKIE_NAME, path=STATE_COOKIE_PATH)
    return response
```

Route:

```python
@router.get("/google/callback")
async def google_callback(
    request: Request,
    code: str | None = None,
    state: str | None = None,
    error: str | None = None,
    oauth_state: str | None = Cookie(default=None),
) -> RedirectResponse:
    if error:
        logger.info("google denied auth: %s", error)
        return _app_redirect(error="access_denied")

    if not state or not oauth_state or state != oauth_state:
        return _app_redirect(error="invalid_state")

    if not code:
        return _app_redirect(error="invalid_callback")

    try:
        id_token_jwt = await exchange_code_for_id_token(code=code)
        email, _sub = verify_id_token(id_token_jwt)
    except GoogleAuthError as exc:
        logger.warning("google oauth handshake failed: %s", exc)
        return _app_redirect(error="server_error")
    except Exception:
        logger.exception("unexpected error in google callback")
        return _app_redirect(error="server_error")

    settings = get_settings()
    if email not in settings.allowed_emails_set:
        logger.info("rejected sign-in for non-allowlisted email: %s", email)
        return _app_redirect(error="not_allowed")

    token = generate_token(num_bytes=settings.session_token_bytes)
    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(days=settings.session_ttl_days)

    async with get_session() as db_session:
        repo = SessionsRepository(db_session)
        await repo.create(
            token_hash=hash_token(token),
            email=email,
            now=now,
            expires_at=expires_at,
        )
        await db_session.commit()

    return _app_redirect(token=token, email=email)
```

- [ ] **Step 4: Run callback tests, expect pass**

Run: `uv run pytest tests/test_auth_routes.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/diet_tracker_server/routers/auth.py tests/test_auth_routes.py
git commit -m "feat(auth): GET /auth/google/callback (token exchange + verify + session create)"
```

---

## Task 10: Auth router — `/auth/whoami` and `/auth/logout`

**Files:**
- Modify: `src/diet_tracker_server/routers/auth.py`, `tests/test_auth_routes.py`

- [ ] **Step 1: Add failing tests**

Append to `tests/test_auth_routes.py`:

```python
def test_whoami_unauthenticated_returns_401(client):
    r = client.get("/auth/whoami")
    assert r.status_code == 401


def test_whoami_returns_email_and_expires_at(client):
    future = datetime.now(timezone.utc) + datetime.now(timezone.utc).utcoffset() if False else None
    from datetime import datetime as DT, timezone as TZ, timedelta as TD
    fut = DT.now(TZ.utc) + TD(days=7)
    fake_repo = AsyncMock()
    fake_repo.get.return_value = {"email": "khashzd@gmail.com", "expires_at": fut}
    fake_repo.slide.return_value = 1

    fake_session = AsyncMock()
    ctx = AsyncMock()
    ctx.__aenter__.return_value = fake_session
    ctx.__aexit__.return_value = None
    with patch("diet_tracker_server.auth.middleware.get_session", return_value=ctx), \
         patch("diet_tracker_server.auth.middleware.SessionsRepository", return_value=fake_repo):
        r = client.get("/auth/whoami", headers={"Authorization": "Bearer tok"})
        assert r.status_code == 200
        body = r.json()
        assert body["email"] == "khashzd@gmail.com"
        assert "expires_at" in body


def test_logout_deletes_session_and_returns_204(client):
    from datetime import datetime as DT, timezone as TZ, timedelta as TD
    fut = DT.now(TZ.utc) + TD(days=7)
    fake_repo = AsyncMock()
    fake_repo.get.return_value = {"email": "u@e.com", "expires_at": fut}
    fake_repo.slide.return_value = 1
    fake_repo.delete.return_value = 1

    fake_session = AsyncMock()
    ctx = AsyncMock()
    ctx.__aenter__.return_value = fake_session
    ctx.__aexit__.return_value = None
    with patch("diet_tracker_server.auth.middleware.get_session", return_value=ctx), \
         patch("diet_tracker_server.auth.middleware.SessionsRepository", return_value=fake_repo), \
         patch("diet_tracker_server.routers.auth.get_session", return_value=ctx), \
         patch("diet_tracker_server.routers.auth.SessionsRepository", return_value=fake_repo):
        r = client.post("/auth/logout", headers={"Authorization": "Bearer tok"})
        assert r.status_code == 204
        fake_repo.delete.assert_awaited()
```

- [ ] **Step 2: Run, expect fail**

Run: `uv run pytest tests/test_auth_routes.py -k "whoami or logout" -v`
Expected: 404s.

- [ ] **Step 3: Add handlers in `routers/auth.py`**

```python
from fastapi import Depends
from pydantic import BaseModel

from diet_tracker_server.auth import require_session


class WhoamiResponse(BaseModel):
    email: str
    expires_at: datetime


@router.get("/whoami", response_model=WhoamiResponse, dependencies=[Depends(require_session)])
async def whoami(request: Request) -> WhoamiResponse:
    return WhoamiResponse(
        email=request.state.email,
        expires_at=request.state.session_expires_at,
    )


@router.post("/logout", status_code=204, dependencies=[Depends(require_session)])
async def logout(request: Request) -> None:
    header = request.headers.get("authorization", "")
    token = header[7:].strip()
    async with get_session() as db_session:
        repo = SessionsRepository(db_session)
        await repo.delete(hash_token(token))
        await db_session.commit()
```

- [ ] **Step 4: Run, expect pass**

Run: `uv run pytest tests/test_auth_routes.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/diet_tracker_server/routers/auth.py tests/test_auth_routes.py
git commit -m "feat(auth): GET /auth/whoami and POST /auth/logout"
```

---

## Task 11: Wire middleware into `app.py` and remove old auth import

**Files:**
- Modify: `src/diet_tracker_server/app.py`

- [ ] **Step 1: Edit `app.py`**

Replace top imports and lifespan:

```python
from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastmcp.utilities.lifespan import combine_lifespans

from diet_tracker_server import db
from diet_tracker_server.auth import SessionAuthMiddleware, UserKeyGuardrailMiddleware
from diet_tracker_server.config import get_settings
from diet_tracker_server.mcp import build_mcp
from diet_tracker_server.routers import (
    auth as auth_router,
    custom_foods as custom_foods_router,
    entries,
    food_memory as food_memory_router,
    logs,
    meals as meals_router,
    summary,
    targets,
)
from diet_tracker_server.routers import usda as usda_router
from diet_tracker_server.usda import USDAClient
```

Remove the line `auth.configure(settings.api_key)` from lifespan (no longer applicable). The lifespan body becomes:

```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    del app
    global usda_client
    settings = get_settings()
    await db.init_pool(settings.database_url)
    await db.bootstrap_schema()
    usda_client = USDAClient(settings.usda_api_key)
    yield
    await usda_client.close()
    await db.close_pool()
```

Register middleware after the `FastAPI(...)` constructor and before `include_router` calls:

```python
app = FastAPI(...)

# Order matters: outermost-first when added. We add SessionAuthMiddleware first so it's the
# innermost (runs after guardrail). The guardrail runs first to short-circuit user_key abuse.
app.add_middleware(SessionAuthMiddleware)
app.add_middleware(UserKeyGuardrailMiddleware)
```

Add `app.include_router(auth_router.router)` (already added in Task 8 — confirm present).

- [ ] **Step 2: Run all tests, expect pass**

Run: `uv run pytest tests/ -v`
Expected: most tests pass; the API_KEY-based ones fail (we'll fix in next tasks).

- [ ] **Step 3: Commit**

```bash
git add src/diet_tracker_server/app.py
git commit -m "feat(auth): mount session middleware + auth router; drop API_KEY config call"
```

---

## Task 12: Strip `?user_key=` query and request-body `user_key` from REST routers and models

**Files:**
- Modify: every router in `src/diet_tracker_server/routers/{entries,logs,summary,targets,custom_foods,food_memory,meals}.py`
- Modify: every model in `src/diet_tracker_server/models/{entries,custom_foods,food_memory,meals}.py` that has a `user_key` request-body field
- Modify: every existing router test that passes `user_key` in body or query

For every router file in scope:

- Replace `from diet_tracker_server.auth import require_api_key` with `from diet_tracker_server.auth import require_session`.
- Replace `dependencies=[Depends(require_api_key)]` with `dependencies=[Depends(require_session)]`.
- Remove every `user_key: str | None = Query(default=None)` parameter.
- Remove every `effective_user_key = user_key or settings.default_user_key` line.
- Add `request: Request` parameter and read `user_key = request.state.user_key`.
- Drop the now-unused `from diet_tracker_server.config import get_settings` if `settings` was only used for `default_user_key` (keep for `timezone` etc).

For every model with a request-body `user_key`:

- Remove the field from `*Create`/`*Request` models (e.g. `EntriesCreateRequest.user_key`). Response models keep their `user_key` field — it's populated from DB rows, not request input.

Per-file diffs (representative; apply consistently across all):

- [ ] **Step 1: Patch `routers/entries.py`**

Before:
```python
from diet_tracker_server.auth import require_api_key
...
router = APIRouter(dependencies=[Depends(require_api_key)])
TZ = ZoneInfo(settings.timezone)

@router.post("/entries", status_code=201, response_model=EntriesCreateResponse)
async def create_entries(
    body: EntriesCreateRequest,
    session: AsyncSession = Depends(get_session_dependency),
) -> EntriesCreateResponse:
    user_key = body.user_key or settings.default_user_key
```

After:
```python
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from diet_tracker_server.auth import require_session
...
router = APIRouter(dependencies=[Depends(require_session)])
TZ = ZoneInfo(settings.timezone)

@router.post("/entries", status_code=201, response_model=EntriesCreateResponse)
async def create_entries(
    request: Request,
    body: EntriesCreateRequest,
    session: AsyncSession = Depends(get_session_dependency),
) -> EntriesCreateResponse:
    user_key = request.state.user_key
```

Apply the same shape to `list_entries` and `delete_entry`. Remove the `user_key: str | None = Query(...)` from `list_entries`.

- [ ] **Step 2: Patch `routers/logs.py`, `routers/summary.py`, `routers/targets.py`, `routers/custom_foods.py`, `routers/food_memory.py`, `routers/meals.py`, `routers/usda.py`**

Apply the same edits. (For `usda.py`, only the auth dep changes — it has no `user_key` query.)

- [ ] **Step 3: Patch `models/entries.py`**

Remove `user_key: str | None = None` from `EntriesCreateRequest`:

```python
class EntriesCreateRequest(BaseModel):
    items: list[FoodEntryCreate]
```

- [ ] **Step 4: Patch other request-body models**

Search for `user_key` fields in *Create / *Request models in `models/custom_foods.py`, `models/food_memory.py`, `models/meals.py`. Drop request-side `user_key` fields. Keep response-side fields.

```bash
grep -n "user_key" src/diet_tracker_server/models/*.py
```

- [ ] **Step 5: Update existing router tests**

For any router test that passes `user_key` in body or query, remove that field/param. Use `client.headers["Authorization"] = "Bearer ..."` (with mocked session repo) or rely on the test client fixture that provides a default session via patching.

(For unit tests in `tests/test_app.py` and `tests/test_mcp_tools.py`, see Task 13.)

- [ ] **Step 6: Run tests**

Run: `uv run pytest tests/ -v -x`
Expected: PASS for the routers that don't yet have updated tests; FAIL only for tests still expecting old auth/query shape (fixed in Task 13).

- [ ] **Step 7: Commit**

```bash
git add src/diet_tracker_server/routers src/diet_tracker_server/models
git commit -m "refactor(routers): drop ?user_key= and body user_key; auth via require_session"
```

---

## Task 13: Update existing tests for new auth

**Files:**
- Modify: `tests/test_app.py`, `tests/test_mcp_tools.py`, any other test using `API_KEY` or sending `?user_key=`

- [ ] **Step 1: Update `tests/test_app.py`**

Replace setup block:

```python
import os
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test")
os.environ.setdefault("GOOGLE_CLIENT_ID", "cid")
os.environ.setdefault("GOOGLE_CLIENT_SECRET", "secret")
os.environ.setdefault("OAUTH_REDIRECT_URI", "https://api.example.com/auth/google/callback")
os.environ.setdefault("APP_REDIRECT_SCHEME", "diettracker")
os.environ.setdefault("ALLOWED_EMAILS", "u@example.com")
os.environ.setdefault("LEGACY_USER_KEY", "default")
os.environ.setdefault("APP_ENV", "local")


def _patch_session_repo(email: str = "u@example.com"):
    fut = datetime.now(timezone.utc) + timedelta(days=7)
    repo = AsyncMock()
    repo.get.return_value = {"email": email, "expires_at": fut}
    repo.slide.return_value = 1
    repo.delete.return_value = 1
    fake_session = AsyncMock()
    ctx = AsyncMock()
    ctx.__aenter__.return_value = fake_session
    ctx.__aexit__.return_value = None
    return repo, ctx


@pytest.fixture
def client() -> TestClient:
    with patch("diet_tracker_server.db.init_pool", new_callable=AsyncMock), \
         patch("diet_tracker_server.db.bootstrap_schema", new_callable=AsyncMock), \
         patch("diet_tracker_server.db.close_pool", new_callable=AsyncMock), \
         patch("diet_tracker_server.usda.USDAClient") as mock_usda:
        mock_usda.return_value.close = AsyncMock()
        from diet_tracker_server.config import get_settings
        get_settings.cache_clear()
        from diet_tracker_server.app import app
        with TestClient(app) as test_client:
            yield test_client


def test_health_check(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_unauthenticated_request_rejected(client: TestClient) -> None:
    response = client.get("/entries", params={"date": "2026-04-05"})
    assert response.status_code == 401


def test_user_key_query_rejected_on_protected_route(client: TestClient) -> None:
    repo, ctx = _patch_session_repo()
    with patch("diet_tracker_server.auth.middleware.get_session", return_value=ctx), \
         patch("diet_tracker_server.auth.middleware.SessionsRepository", return_value=repo):
        r = client.get(
            "/entries?date=2026-04-05&user_key=hacker",
            headers={"Authorization": "Bearer tok"},
        )
        assert r.status_code == 400
```

- [ ] **Step 2: Update `tests/test_mcp_tools.py`**

`grep` for `API_KEY` and replace with the new env shape. The MCP layer doesn't share auth with REST, so existing MCP tool tests should still pass once the env names are corrected.

```bash
grep -n "API_KEY\|api_key" tests/test_mcp_tools.py
```

Apply env changes; if tests directly reference `settings.api_key`, replace with the new env vars or remove (the local-dev MCP fallback is being removed).

- [ ] **Step 3: Run all unit tests**

Run: `uv run pytest tests/ -v --ignore=tests/integration`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add tests/
git commit -m "test: rewrite app + mcp tests for Bearer auth and env shape"
```

---

## Task 14: Drop MCP X-API-Key fallback

**Files:**
- Modify: `src/diet_tracker_server/mcp/server.py`, `src/diet_tracker_server/mcp/auth.py`
- Modify: `tests/test_mcp_tools.py` if relevant

- [ ] **Step 1: Edit `mcp/server.py`**

Replace the auth setup block:

```python
if settings.mcp_oauth_enabled:
    from fastmcp.server.auth.providers.github import GitHubProvider
    auth_provider = GitHubProvider(
        client_id=settings.github_client_id,
        client_secret=settings.github_client_secret,
        base_url=settings.public_base_url.rstrip("/"),
    )
    mcp = FastMCP(name="diet", instructions=WORKFLOW_INSTRUCTIONS, auth=auth_provider)
    if settings.allowed_github_users_set:
        mcp.add_middleware(GitHubAllowlistMiddleware(settings.allowed_github_users_set))
else:
    # Local dev: MCP layer runs unauth. Production must set GITHUB_CLIENT_ID/SECRET + PUBLIC_BASE_URL.
    mcp = FastMCP(name="diet", instructions=WORKFLOW_INSTRUCTIONS)
```

`user_key = settings.default_user_key` stays — MCP is single-user-per-server today (matching previous behavior).

(Open question: is this the right call? See "Open Questions" below.)

- [ ] **Step 2: Delete `ApiKeyMiddleware` from `mcp/auth.py`**

Remove the `ApiKeyMiddleware` class. Keep `GitHubAllowlistMiddleware`. Update the import in `mcp/server.py` accordingly:

```python
from diet_tracker_server.mcp.auth import GitHubAllowlistMiddleware
```

- [ ] **Step 3: Run tests**

Run: `uv run pytest tests/ -v`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/diet_tracker_server/mcp tests/
git commit -m "refactor(mcp): drop X-API-Key fallback (rely on GitHub OAuth or local unauth)"
```

---

## Task 15: Integration test — end-to-end sign-in → call → logout

**Files:**
- Create: `tests/integration/test_auth_integration.py`

- [ ] **Step 1: Write failing test**

```python
from __future__ import annotations

import os
from datetime import datetime, timezone
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

pytestmark = pytest.mark.integration


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    if not os.environ.get("TEST_DATABASE_URL"):
        pytest.skip("TEST_DATABASE_URL not set")
    monkeypatch.setenv("DATABASE_URL", os.environ["TEST_DATABASE_URL"])
    monkeypatch.setenv("USDA_API_KEY", "x")
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "cid")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "secret")
    monkeypatch.setenv("OAUTH_REDIRECT_URI", "https://api.example.com/auth/google/callback")
    monkeypatch.setenv("APP_REDIRECT_SCHEME", "diettracker")
    monkeypatch.setenv("ALLOWED_EMAILS", "khashzd@gmail.com")
    monkeypatch.setenv("LEGACY_USER_KEY", "khash")
    monkeypatch.setenv("APP_ENV", "local")
    from diet_tracker_server.config import get_settings
    get_settings.cache_clear()


@pytest.fixture
def client():
    with patch("diet_tracker_server.usda.USDAClient") as mock_usda:
        mock_usda.return_value.close = AsyncMock()
        from diet_tracker_server.app import app
        with TestClient(app) as c:
            # truncate sessions
            from diet_tracker_server import db
            import asyncio, sqlalchemy as sa
            async def _truncate():
                async with db.get_session() as s:
                    await s.execute(sa.text("truncate sessions"))
                    await s.commit()
            asyncio.get_event_loop().run_until_complete(_truncate())
            yield c


def test_full_signin_flow(client):
    # /start
    r = client.get("/auth/google/start", follow_redirects=False)
    assert r.status_code == 302
    state_cookie = r.cookies.get("oauth_state")
    assert state_cookie

    # /callback (mock Google)
    with patch(
        "diet_tracker_server.routers.auth.exchange_code_for_id_token",
        new_callable=AsyncMock, return_value="jwt",
    ), patch(
        "diet_tracker_server.routers.auth.verify_id_token",
        return_value=("khashzd@gmail.com", "sub"),
    ):
        client.cookies.set("oauth_state", state_cookie, path="/auth/google")
        r = client.get(
            "/auth/google/callback",
            params={"code": "x", "state": state_cookie},
            follow_redirects=False,
        )
    assert r.status_code == 302
    loc = r.headers["location"]
    assert loc.startswith("diettracker://auth?token=")
    token = loc.split("token=")[1].split("&")[0]
    assert token

    # whoami
    r = client.get("/auth/whoami", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    assert r.json()["email"] == "khashzd@gmail.com"

    # logout
    r = client.post("/auth/logout", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 204

    # whoami again -> 401
    r = client.get("/auth/whoami", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 401
```

- [ ] **Step 2: Run, expect pass**

Run: `TEST_DATABASE_URL=postgresql://localhost/diet_test uv run pytest tests/integration/test_auth_integration.py -v -m integration`
Expected: PASS (or skip if no DB).

- [ ] **Step 3: Commit**

```bash
git add tests/integration/test_auth_integration.py
git commit -m "test(integration): end-to-end google oauth signin flow"
```

---

## Task 16: README / runbook updates

**Files:**
- Modify: `CLAUDE.md` (drop `API_KEY` in env list if mentioned; note new envs)
- Modify: `README.md` if it documents `X-API-Key` usage

- [ ] **Step 1: Audit docs**

```bash
grep -n "X-API-Key\|API_KEY\|api_key" CLAUDE.md README.md 2>/dev/null
```

- [ ] **Step 2: Update mentions**

Replace `X-API-Key` flow with the Google OAuth env list:
- `GOOGLE_CLIENT_ID`
- `GOOGLE_CLIENT_SECRET`
- `OAUTH_REDIRECT_URI`
- `APP_REDIRECT_SCHEME`
- `ALLOWED_EMAILS`
- `SESSION_TTL_DAYS` (default 90)
- `LEGACY_USER_KEY`

Note that the iOS client now sends `Authorization: Bearer <token>` and never `?user_key=`.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md 2>/dev/null
git commit -m "docs: document Google OAuth env vars and Bearer auth"
```

---

## Task 17: Final pass — full test run + cutover guardrail manual check

- [ ] **Step 1: Full test suite**

Run: `uv run pytest tests/ -v`
Expected: PASS.

- [ ] **Step 2: Integration tests (if DB available)**

Run: `TEST_DATABASE_URL=postgresql://localhost/diet_test uv run pytest tests/integration -v -m integration`
Expected: PASS.

- [ ] **Step 3: Local smoke**

```bash
uv run uvicorn diet_tracker_server.app:app --port 8787 &
sleep 1
curl -i http://localhost:8787/health
curl -i http://localhost:8787/entries?date=2026-04-05
# expect 401
curl -i "http://localhost:8787/entries?date=2026-04-05&user_key=foo" -H "Authorization: Bearer notreal"
# expect 400 (guardrail) — but only after auth passes; current behavior is 401 first.
# Confirm the order in middleware matches the spec's intent.
kill %1
```

- [ ] **Step 4: Open PR**

```bash
git push -u origin feat/google-oauth
gh pr create --title "feat(auth): Google OAuth login + bearer sessions, drop API_KEY" --body "..."
```

---

## Open Questions

- MCP local fallback: spec removes `API_KEY` entirely. Plan currently makes MCP unauth in local dev when `mcp_oauth_enabled` is false. Acceptable for prod (we always set GitHub envs in prod), but means anyone who reaches a local server can call MCP tools. Want a separate `MCP_LOCAL_DEV_KEY` env to keep the X-API-Key fallback alive locally only?
- Auth-routes guardrail: spec says guardrail rejects `?user_key=` on "non-`/auth/*` route". Plan also exempts `/health`. Confirm.
- Middleware order: guardrail runs before auth, so `/entries?user_key=foo` without Bearer returns 400 (not 401). Spec is silent. Acceptable?
- Token encoding: plan uses `urlsafe_b64encode(...).rstrip(b"=")` (43 chars for 32 bytes). Spec mentions "base64url without padding". Match.
- Cleanup of guardrail: spec says remove in next release. Plan doesn't include the cleanup task. Track separately?
- `LEGACY_USER_KEY` default: plan defaults to `"khash"` (matches prod auto-memory). Confirm before merge.
- `APP_REDIRECT_SCHEME` default: plan defaults to `"diettracker"`. Confirm.
