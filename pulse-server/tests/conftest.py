"""Shared pytest fixtures and env setup.

Provides a single source of truth for the env vars the new Bearer-auth path
expects and exposes a small helper to patch the SessionsRepository so unit
tests can exercise authenticated REST routes without a real database.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone
from typing import Any
from unittest.mock import AsyncMock

# Module-level env defaults so test files that import the app at import time
# (via `from diet_tracker_server.app import app`) succeed before any fixture
# runs.
os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test-usda")
os.environ.setdefault("GOOGLE_CLIENT_ID", "cid.apps.googleusercontent.com")
os.environ.setdefault("GOOGLE_CLIENT_SECRET", "secret")
os.environ.setdefault("OAUTH_REDIRECT_URI", "https://api.example.com/auth/google/callback")
os.environ.setdefault("APP_REDIRECT_SCHEME", "diettracker")
os.environ.setdefault("ALLOWED_EMAILS", "khashzd@gmail.com")
os.environ.setdefault("LEGACY_USER_KEY", "khash")
os.environ.setdefault("APP_ENV", "local")


# Summary: Builds an AsyncMock SessionsRepository + async-context pair the auth
# middleware can use. The repo returns a non-expired session for `khashzd@gmail.com`
# unless overridden, so callers get a clean happy-path setup.
# Parameters:
# - email (str): Email value the fake session row reports.
# Returns:
# - tuple[AsyncMock, AsyncMock]: (repo, ctx) where `ctx` is the async-context
#   wrapper to substitute for `get_session`.
# Raises/Throws:
# - None: Pure constructor.
def patched_session_repo(email: str = "khashzd@gmail.com") -> tuple[AsyncMock, AsyncMock]:
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


# Summary: Convenience kwargs for `unittest.mock.patch` calls that route the
# middleware through the patched session repo.
# Parameters:
# - email (str): Email returned by the patched repo.get call.
# Returns:
# - dict[str, Any]: Mapping of import paths to patched objects suitable for use
#   with `patch.multiple` or stacked `patch` context managers.
# Raises/Throws:
# - None: Pure helper.
def session_patch_targets(email: str = "khashzd@gmail.com") -> dict[str, Any]:
    repo, ctx = patched_session_repo(email)
    return {"repo": repo, "ctx": ctx}
