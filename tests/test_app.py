from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient


# Summary: Builds an AsyncMock SessionsRepository + async-context pair the auth
# middleware can use to short-circuit the DB lookup during unit tests.
# Parameters:
# - email (str): Email value the fake session row reports.
# Returns:
# - tuple[AsyncMock, AsyncMock]: (repo, ctx) suitable for patching
#   `SessionsRepository` and `get_session` respectively.
# Raises/Throws:
# - None: Pure constructor.
def _patched_session_repo(email: str = "khashzd@gmail.com") -> tuple[AsyncMock, AsyncMock]:
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


# Summary: Builds a TestClient with lifespan dependencies mocked for isolated API tests.
# Parameters:
# - None: Uses module-level environment defaults and mock patches.
# Returns:
# - TestClient: Client bound to the app under test.
# Raises/Throws:
# - None: Fixture yields a configured client or fails test setup naturally.
@pytest.fixture
def client() -> TestClient:
    with patch("diet_tracker_server.db.init_pool", new_callable=AsyncMock), patch(
        "diet_tracker_server.db.bootstrap_schema", new_callable=AsyncMock
    ), patch("diet_tracker_server.db.close_pool", new_callable=AsyncMock), patch(
        "diet_tracker_server.usda.USDAClient"
    ) as mock_usda_client:
        mock_usda_client.return_value.close = AsyncMock()
        from diet_tracker_server.app import app

        with TestClient(app) as test_client:
            yield test_client


# Summary: Verifies the app health endpoint returns success status.
# Parameters:
# - client (TestClient): Fixture-provided HTTP client for app requests.
# Returns:
# - None: Performs status and payload assertions only.
# Raises/Throws:
# - AssertionError: Raised when health response does not match expectations.
def test_health_check(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


# Summary: Verifies protected endpoints reject requests without a Bearer token.
# Parameters:
# - client (TestClient): Fixture-provided HTTP client for app requests.
# Returns:
# - None: Performs status assertions only.
# Raises/Throws:
# - AssertionError: Raised when unauthenticated access is not rejected.
def test_unauthenticated_request_rejected(client: TestClient) -> None:
    response = client.get("/entries", params={"date": "2026-04-05"})
    assert response.status_code == 401


# Summary: Confirms the user_key query guardrail returns 400 on protected routes
# even when an otherwise-valid Bearer token is supplied.
# Parameters:
# - client (TestClient): Fixture-provided HTTP client for app requests.
# Returns:
# - None: Performs status and payload assertions only.
# Raises/Throws:
# - AssertionError: Raised when guardrail does not return 400.
def test_user_key_query_rejected_on_protected_route(client: TestClient) -> None:
    repo, ctx = _patched_session_repo()
    with patch("diet_tracker_server.auth.middleware.get_session", return_value=ctx), patch(
        "diet_tracker_server.auth.middleware.SessionsRepository", return_value=repo
    ):
        response = client.get(
            "/entries?user_key=foo&date=2026-04-05",
            headers={"Authorization": "Bearer tok"},
        )
    assert response.status_code == 400
    assert "user_key" in (response.json().get("error") or "")
