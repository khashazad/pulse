import os
from uuid import uuid4

import pytest

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test")
os.environ.setdefault("API_KEY", "test")


def test_food_entry_create_accepts_usda_only() -> None:
    from nutrition_server.models import FoodEntryCreate

    entry = FoodEntryCreate(
        display_name="eggs",
        quantity_text="2 eggs",
        usda_fdc_id=171287,
        usda_description="Egg",
        calories=140,
        protein_g=12,
        carbs_g=1,
        fat_g=10,
    )
    assert entry.usda_fdc_id == 171287
    assert entry.custom_food_id is None


def test_food_entry_create_accepts_custom_only() -> None:
    from nutrition_server.models import FoodEntryCreate

    cf_id = uuid4()
    entry = FoodEntryCreate(
        display_name="my wrap",
        quantity_text="1 wrap",
        custom_food_id=cf_id,
        calories=350,
        protein_g=20,
        carbs_g=30,
        fat_g=15,
    )
    assert entry.custom_food_id == cf_id
    assert entry.usda_fdc_id is None


def test_food_entry_create_rejects_both_sources() -> None:
    from nutrition_server.models import FoodEntryCreate

    with pytest.raises(Exception):
        FoodEntryCreate(
            display_name="x",
            quantity_text="1",
            usda_fdc_id=1,
            usda_description="x",
            custom_food_id=uuid4(),
            calories=0,
            protein_g=0,
            carbs_g=0,
            fat_g=0,
        )


def test_food_entry_create_rejects_neither_source() -> None:
    from nutrition_server.models import FoodEntryCreate

    with pytest.raises(Exception):
        FoodEntryCreate(
            display_name="x",
            quantity_text="1",
            calories=0,
            protein_g=0,
            carbs_g=0,
            fat_g=0,
        )


def test_food_entry_create_rejects_missing_usda_description() -> None:
    from nutrition_server.models import FoodEntryCreate

    with pytest.raises(Exception):
        FoodEntryCreate(
            display_name="x",
            quantity_text="1",
            usda_fdc_id=1,
            calories=0,
            protein_g=0,
            carbs_g=0,
            fat_g=0,
        )
