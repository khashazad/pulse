"""Unit tests for `services.weight_service` helpers.

Covers `normalize_to_lb` (passthrough for lb, kg→lb conversion, banker's
rounding) and `validate_range` (366-day inclusive cap, reversed-range
rejection), plus the `MAX_RANGE_DAYS` constant.
"""

from __future__ import annotations

from datetime import date, timedelta
from decimal import Decimal

import pytest

from pulse_server.services.weight_service import (
    MAX_RANGE_DAYS,
    normalize_to_lb,
    validate_range,
)


def test_normalize_passthrough_lb() -> None:
    """`normalize_to_lb` returns lb input unchanged."""
    assert normalize_to_lb(Decimal("180.50"), unit="lb") == Decimal("180.50")


def test_normalize_kg_to_lb() -> None:
    """`normalize_to_lb` converts kg to lb using the documented factor."""
    assert normalize_to_lb(Decimal("70"), unit="kg") == Decimal("154.32")


def test_normalize_kg_rounds_half_even() -> None:
    """`normalize_to_lb` rounds half-to-even to two decimal places."""
    assert normalize_to_lb(Decimal("1"), unit="kg") == Decimal("2.20")


def test_validate_range_accepts_366_days() -> None:
    """`validate_range` accepts a span of exactly 366 days."""
    validate_range(date(2024, 1, 1), date(2024, 1, 1) + timedelta(days=366))


def test_validate_range_rejects_over_366() -> None:
    """`validate_range` rejects spans wider than 366 days with `ValueError`."""
    with pytest.raises(ValueError):
        validate_range(date(2024, 1, 1), date(2024, 1, 1) + timedelta(days=367))


def test_validate_range_rejects_reversed() -> None:
    """`validate_range` rejects ranges where `to` precedes `from`."""
    with pytest.raises(ValueError):
        validate_range(date(2024, 1, 2), date(2024, 1, 1))


def test_max_range_days_constant() -> None:
    """`MAX_RANGE_DAYS` is the documented 366-day cap."""
    assert MAX_RANGE_DAYS == 366
