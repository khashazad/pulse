"""Validation tests for `FoodEntryCreate` and `FoodEntryResponse`.

Covers acceptance of USDA-only and custom-food-only payloads, rejection
of both-set / neither-set / missing-USDA-description payloads, the
guarantee that client-supplied `meal_id` / `meal_name` are dropped on
the way in, and the serialization of those fields on the response model.
"""

from datetime import datetime, timezone
from uuid import UUID, uuid4

import pytest

from diet_tracker_server.models.entries import FoodEntryCreate, FoodEntryResponse


def test_food_entry_create_accepts_usda_only() -> None:
    """USDA-only payload is accepted and ``custom_food_id`` defaults to ``None``."""
    from diet_tracker_server.models import FoodEntryCreate

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
    """Custom-food-only payload is accepted and ``usda_fdc_id`` defaults to ``None``."""
    from diet_tracker_server.models import FoodEntryCreate

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
    """Specifying both USDA and custom-food sources fails validation."""
    from diet_tracker_server.models import FoodEntryCreate

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
    """Omitting both USDA and custom-food sources fails validation."""
    from diet_tracker_server.models import FoodEntryCreate

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
    """A USDA payload without `usda_description` fails validation."""
    from diet_tracker_server.models import FoodEntryCreate

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


def test_food_entry_create_does_not_expose_meal_link_fields() -> None:
    """`FoodEntryCreate.model_fields` does not declare `meal_id` or `meal_name`."""
    fields = FoodEntryCreate.model_fields
    assert "meal_id" not in fields
    assert "meal_name" not in fields


def test_food_entry_create_ignores_client_supplied_meal_link() -> None:
    """Client-supplied `meal_id` / `meal_name` are dropped during validation."""
    # meal_id / meal_name are server-controlled (only set by log_meal). When clients
    # try to forge them in the public payload, FoodEntryCreate must not surface them
    # as attributes that downstream code could trust.
    entry = FoodEntryCreate.model_validate({
        "display_name": "oats",
        "quantity_text": "80 g",
        "usda_fdc_id": 173904,
        "usda_description": "Oats, raw",
        "calories": 320,
        "protein_g": 10,
        "carbs_g": 54,
        "fat_g": 6,
        "meal_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "meal_name": "Forged Meal",
    })
    assert not hasattr(entry, "meal_id")
    assert not hasattr(entry, "meal_name")


def test_food_entry_response_serializes_meal_link() -> None:
    """`FoodEntryResponse` serializes `meal_id` and `meal_name` when set."""
    meal_id = UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    response = FoodEntryResponse(
        id=UUID("11111111-1111-1111-1111-111111111111"),
        daily_log_id=UUID("22222222-2222-2222-2222-222222222222"),
        user_key="khash",
        entry_group_id=UUID("33333333-3333-3333-3333-333333333333"),
        display_name="oats",
        quantity_text="80 g",
        normalized_quantity_value=80.0,
        normalized_quantity_unit="g",
        usda_fdc_id=173904,
        usda_description="Oats, raw",
        calories=320,
        protein_g=10,
        carbs_g=54,
        fat_g=6,
        meal_id=meal_id,
        meal_name="Breakfast",
        consumed_at=datetime(2026, 5, 6, 8, 30, tzinfo=timezone.utc),
        created_at=datetime(2026, 5, 6, 8, 31, tzinfo=timezone.utc),
    )
    assert response.meal_id == meal_id
    assert response.meal_name == "Breakfast"
    dumped = response.model_dump()
    assert dumped["meal_id"] == meal_id
    assert dumped["meal_name"] == "Breakfast"


def test_food_entry_response_meal_link_defaults_to_none() -> None:
    """`FoodEntryResponse.meal_id` and `meal_name` default to `None` when unset."""
    response = FoodEntryResponse(
        id=UUID("11111111-1111-1111-1111-111111111111"),
        daily_log_id=UUID("22222222-2222-2222-2222-222222222222"),
        user_key="khash",
        entry_group_id=UUID("33333333-3333-3333-3333-333333333333"),
        display_name="oats",
        quantity_text="80 g",
        normalized_quantity_value=None,
        normalized_quantity_unit=None,
        usda_fdc_id=173904,
        usda_description="Oats, raw",
        calories=320,
        protein_g=10,
        carbs_g=54,
        fat_g=6,
        consumed_at=datetime(2026, 5, 6, 8, 30, tzinfo=timezone.utc),
        created_at=datetime(2026, 5, 6, 8, 31, tzinfo=timezone.utc),
    )
    assert response.meal_id is None
    assert response.meal_name is None
