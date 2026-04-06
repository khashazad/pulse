import pytest


# Summary: Validates that Settings reads required values from environment variables.
# Parameters:
# - monkeypatch (pytest.MonkeyPatch): Fixture used to set temporary environment values.
# Returns:
# - None: The test performs assertions only.
# Raises/Throws:
# - AssertionError: Raised when actual settings values differ from expectations.
def test_settings_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql://localhost/test")
    monkeypatch.setenv("USDA_API_KEY", "test-usda-key")
    monkeypatch.setenv("API_KEY", "test-api-key")

    from nutrition_server.config import Settings

    settings = Settings()
    assert settings.database_url == "postgresql://localhost/test"
    assert settings.usda_api_key == "test-usda-key"
    assert settings.api_key == "test-api-key"
    assert settings.default_user_key == "default"
    assert settings.port == 8787
    assert settings.timezone == "America/Toronto"


# Summary: Ensures that Settings validation fails when DATABASE_URL is missing.
# Parameters:
# - monkeypatch (pytest.MonkeyPatch): Fixture used to clear and set environment values.
# Returns:
# - None: The test only validates exception behavior.
# Raises/Throws:
# - AssertionError: Raised when Settings unexpectedly initializes without DATABASE_URL.
def test_settings_requires_database_url(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("USDA_API_KEY", "k")
    monkeypatch.setenv("API_KEY", "k")

    from nutrition_server.config import Settings

    with pytest.raises(Exception):
        Settings()
