"""Unit tests for foods_service pure helpers."""

from __future__ import annotations

import pytest

from pulse_server.services.foods_service import derive_portion_label


@pytest.mark.parametrize(
    "food_name,portion_name,expected",
    [
        ("Apple", "medium apple", "medium"),
        ("Apple", "apple per 100g", "per 100g"),
        ("Apple", "Large Apple", "Large"),
        ("Apple", "apple", "apple"),
        ("Greek Yogurt", "greek yogurt small", "small"),
    ],
)
def test_derive_portion_label(food_name, portion_name, expected):
    assert derive_portion_label(food_name, portion_name) == expected
