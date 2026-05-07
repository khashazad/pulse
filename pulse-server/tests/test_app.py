import os
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test")
os.environ.setdefault("API_KEY", "test-key")


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


# Summary: Verifies protected endpoints reject requests without a valid API key.
# Parameters:
# - client (TestClient): Fixture-provided HTTP client for app requests.
# Returns:
# - None: Performs status assertions only.
# Raises/Throws:
# - AssertionError: Raised when unauthenticated access is not rejected.
def test_unauthenticated_request_rejected(client: TestClient) -> None:
    response = client.get("/entries", params={"date": "2026-04-05"})
    assert response.status_code == 401
