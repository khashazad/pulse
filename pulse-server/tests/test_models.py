import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient
from unittest.mock import patch


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

    settings = Settings(_env_file=None)
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
        Settings(_env_file=None)


# Summary: Verifies auth dependency rejects requests without a matching API key header.
# Parameters:
# - None: Uses an in-memory FastAPI app and patched auth configuration.
# Returns:
# - None: The test performs HTTP status assertions only.
# Raises/Throws:
# - AssertionError: Raised if unauthorized requests are not rejected.
def test_auth_rejects_missing_key() -> None:
    with patch("nutrition_server.auth._configured_key", "secret"):
        from nutrition_server.auth import require_api_key

        app = FastAPI()

        # Summary: Test endpoint guarded by API-key dependency.
        # Parameters:
        # - key (str): Resolved dependency value from the auth checker.
        # Returns:
        # - dict[str, bool]: Response payload indicating success.
        # Raises/Throws:
        # - fastapi.HTTPException: Propagated when dependency authorization fails.
        @app.get("/test")
        def endpoint(key: str = Depends(require_api_key)) -> dict[str, bool]:
            _ = key
            return {"ok": True}

        client = TestClient(app)
        response = client.get("/test")
        assert response.status_code == 401


# Summary: Verifies auth dependency accepts requests containing the configured API key.
# Parameters:
# - None: Uses an in-memory FastAPI app and patched auth configuration.
# Returns:
# - None: The test performs HTTP status assertions only.
# Raises/Throws:
# - AssertionError: Raised if authorized requests are rejected.
def test_auth_accepts_valid_key() -> None:
    with patch("nutrition_server.auth._configured_key", "secret"):
        from nutrition_server.auth import require_api_key

        app = FastAPI()

        # Summary: Test endpoint guarded by API-key dependency.
        # Parameters:
        # - key (str): Resolved dependency value from the auth checker.
        # Returns:
        # - dict[str, bool]: Response payload indicating success.
        # Raises/Throws:
        # - fastapi.HTTPException: Propagated when dependency authorization fails.
        @app.get("/test")
        def endpoint(key: str = Depends(require_api_key)) -> dict[str, bool]:
            _ = key
            return {"ok": True}

        client = TestClient(app)
        response = client.get("/test", headers={"X-API-Key": "secret"})
        assert response.status_code == 200


# Summary: Confirms valid food-entry payloads are accepted by FoodEntryCreate.
# Parameters:
# - None: Uses hardcoded representative payload data.
# Returns:
# - None: Performs field assertions only.
# Raises/Throws:
# - AssertionError: Raised when parsed model values are unexpected.
def test_food_entry_create_validation() -> None:
    from nutrition_server.models import FoodEntryCreate

    entry = FoodEntryCreate(
        display_name="eggs",
        quantity_text="3 eggs",
        usda_fdc_id=171287,
        usda_description="Egg, whole, raw",
        calories=216,
        protein_g=18.9,
        carbs_g=1.1,
        fat_g=14.3,
    )
    assert entry.display_name == "eggs"
    assert entry.date is None


# Summary: Ensures FoodEntryCreate rejects payloads with negative calories.
# Parameters:
# - None: Uses a payload with an invalid negative calorie value.
# Returns:
# - None: Validates exception behavior.
# Raises/Throws:
# - AssertionError: Raised when invalid payloads do not fail validation.
def test_food_entry_create_rejects_negative_calories() -> None:
    from nutrition_server.models import FoodEntryCreate

    with pytest.raises(Exception):
        FoodEntryCreate(
            display_name="eggs",
            quantity_text="3 eggs",
            usda_fdc_id=171287,
            usda_description="Egg",
            calories=-100,
            protein_g=0,
            carbs_g=0,
            fat_g=0,
        )


# Summary: Confirms macro target payloads are parsed and validated successfully.
# Parameters:
# - None: Uses a valid macro target payload.
# Returns:
# - None: Performs field assertions only.
# Raises/Throws:
# - AssertionError: Raised when parsed model values are unexpected.
def test_macro_targets_validation() -> None:
    from nutrition_server.models import MacroTargets

    targets = MacroTargets(calories=2000, protein_g=150.0, carbs_g=200.0, fat_g=80.0)
    assert targets.calories == 2000
