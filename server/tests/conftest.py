"""Shared pytest env defaults.

Module-level env defaults so test files that import the app at import time
(via `from pulse_server.app import app`) succeed before any fixture
runs.
"""

from __future__ import annotations

import os
from datetime import datetime as DateTimeValue
from datetime import timedelta as TimeDeltaValue
from datetime import timezone as TimezoneValue
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test-usda")
os.environ.setdefault("GOOGLE_CLIENT_ID", "cid.apps.googleusercontent.com")
os.environ.setdefault("GOOGLE_CLIENT_SECRET", "secret")
os.environ.setdefault("OAUTH_REDIRECT_URI", "https://api.example.com/auth/google/callback")
os.environ.setdefault("APP_REDIRECT_SCHEME", "diettracker")
os.environ.setdefault("ALLOWED_EMAILS", "khashzd@gmail.com")
os.environ.setdefault("LEGACY_USER_KEY", "khash")
os.environ.setdefault("APP_ENV", "local")


# Header that makes a request pass the mocked session middleware below.
AUTH_HEADERS = {"Authorization": "Bearer tok"}


@pytest.fixture
def rest_client() -> TestClient:
    """TestClient with the DB pool, USDA client, and session middleware mocked.

    Bearer-authenticated requests pass auth (the session repository is mocked to
    return a valid, unexpired session for ``khashzd@gmail.com``); requests with
    no ``Authorization`` header still hit the real middleware and get 401. The
    request-scoped DB session is overridden with a ``MagicMock`` whose
    ``begin()`` returns a working async context manager so ``transaction(...)``
    blocks run without a real database. This mirrors the inline fixtures in
    ``test_containers_api.py`` / ``test_weight_routes.py`` so the per-router
    unit tests can patch the repository class they exercise.

    **Outputs:**
    - TestClient: Client bound to the configured app, cleaned up on teardown.
    """
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    fut = now + TimeDeltaValue(days=7)
    session_repo = AsyncMock()
    session_repo.get.return_value = {"email": "khashzd@gmail.com", "expires_at": fut}
    session_repo.slide.return_value = 1
    session_repo.delete.return_value = 1
    fake_db_session = AsyncMock()
    db_ctx = AsyncMock()
    db_ctx.__aenter__.return_value = fake_db_session
    db_ctx.__aexit__.return_value = None

    with patch("pulse_server.db.init_pool", new_callable=AsyncMock), patch(
        "pulse_server.db.bootstrap_schema", new_callable=AsyncMock
    ), patch("pulse_server.db.close_pool", new_callable=AsyncMock), patch(
        "pulse_server.usda.USDAClient"
    ) as mock_usda_client, patch(
        "pulse_server.auth.middleware.get_session", return_value=db_ctx
    ), patch(
        "pulse_server.auth.middleware.SessionsRepository", return_value=session_repo
    ):
        mock_usda_client.return_value.close = AsyncMock()
        from pulse_server.app import app
        from pulse_server.db import get_session_dependency

        async def _fake_session_dep():
            """Yield a `MagicMock` DB session with a working async `begin()` ctx."""
            session = MagicMock()
            session.begin = MagicMock()
            session.begin.return_value.__aenter__ = AsyncMock(return_value=session)
            session.begin.return_value.__aexit__ = AsyncMock(return_value=False)
            yield session

        app.dependency_overrides[get_session_dependency] = _fake_session_dep
        try:
            with TestClient(app) as test_client:
                yield test_client
        finally:
            app.dependency_overrides.pop(get_session_dependency, None)
