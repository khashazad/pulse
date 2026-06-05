"""Lightweight model and `Settings` validation tests.

Covers env-driven `Settings` parsing (required `DATABASE_URL`),
`FoodEntryCreate` accept/reject paths for valid and negative-calorie
payloads, `MacroTargets` validation, and aliases defaults on
`FoodMemoryEntry` and `MealSummary`.
"""

import pytest


def test_settings_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """`Settings` populates required and default fields from env vars."""
    monkeypatch.setenv("DATABASE_URL", "postgresql://localhost/test")
    monkeypatch.setenv("USDA_API_KEY", "test-usda-key")
    monkeypatch.setenv("LEGACY_USER_KEY", "khash")

    from pulse_server.config import Settings

    settings = Settings(_env_file=None)
    assert settings.database_url == "postgresql://localhost/test"
    assert settings.usda_api_key == "test-usda-key"
    assert settings.legacy_user_key == "khash"
    assert settings.port == 8787
    assert settings.timezone == "America/Toronto"


def test_settings_requires_database_url(monkeypatch: pytest.MonkeyPatch) -> None:
    """`Settings` raises when `DATABASE_URL` is missing from the environment."""
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("USDA_API_KEY", "k")

    from pulse_server.config import Settings

    with pytest.raises(Exception):
        Settings(_env_file=None)


def test_food_entry_create_validation() -> None:
    """A typical USDA-backed payload is accepted by `FoodEntryCreate`."""
    from pulse_server.models import FoodEntryCreate

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
    assert entry.consumed_at is None


def test_food_entry_create_rejects_negative_calories() -> None:
    """Negative `calories` is rejected by `FoodEntryCreate`."""
    from pulse_server.models import FoodEntryCreate

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


def test_macro_targets_validation() -> None:
    """A valid `MacroTargets` payload parses with expected field values."""
    from pulse_server.models import MacroTargets

    targets = MacroTargets(calories=2000, protein_g=150.0, carbs_g=200.0, fat_g=80.0)
    assert targets.calories == 2000


def test_food_memory_table_has_aliases_column() -> None:
    """`food_memory` and `meals` tables both expose an `aliases` column."""
    from pulse_server.repositories.tables import food_memory, meals

    assert "aliases" in food_memory.c
    assert "aliases" in meals.c


def test_food_memory_entry_aliases_defaults_to_empty_list() -> None:
    """`FoodMemoryEntry.aliases` defaults to `[]` when not provided."""
    from datetime import datetime
    from uuid import uuid4

    from pulse_server.models import FoodMemoryEntry

    entry = FoodMemoryEntry(
        id=uuid4(),
        user_key="khash",
        name="PB",
        normalized_name="pb",
        usda_fdc_id=1,
        usda_description="PB",
        basis="per_100g",
        calories=100,
        protein_g=1.0,
        carbs_g=1.0,
        fat_g=1.0,
        created_at=datetime.now(),
        updated_at=datetime.now(),
    )
    assert entry.aliases == []


def test_meal_summary_aliases_defaults_to_empty_list() -> None:
    """`MealSummary.aliases` defaults to `[]` when not provided."""
    from uuid import uuid4

    from pulse_server.models import MealSummary

    summary = MealSummary(
        id=uuid4(),
        name="Wrap",
        normalized_name="wrap",
        notes=None,
        item_count=0,
    )
    assert summary.aliases == []


def test_custom_food_update_omitted_fields_are_noop() -> None:
    """Omitting a field leaves it out of `model_dump(exclude_unset=True)`."""
    from pulse_server.models import CustomFoodUpdate

    patch = CustomFoodUpdate(notes="from a photo")
    dumped = patch.model_dump(exclude_unset=True)
    assert dumped == {"notes": "from a photo"}


def test_custom_food_update_allows_null_for_nullable_fields() -> None:
    """Explicit null is allowed for the nullable columns (serving_size, notes, unit)."""
    from pulse_server.models import CustomFoodUpdate

    patch = CustomFoodUpdate(serving_size=None, serving_size_unit=None, notes=None)
    dumped = patch.model_dump(exclude_unset=True)
    assert dumped == {"serving_size": None, "serving_size_unit": None, "notes": None}


@pytest.mark.parametrize(
    "field",
    ["name", "basis", "calories", "protein_g", "carbs_g", "fat_g", "source"],
)
def test_custom_food_update_rejects_null_for_non_nullable_fields(field: str) -> None:
    """Explicitly setting a NOT NULL column to null is rejected at the model layer."""
    from pulse_server.models import CustomFoodUpdate

    with pytest.raises(Exception, match="cannot be null"):
        CustomFoodUpdate(**{field: None})
