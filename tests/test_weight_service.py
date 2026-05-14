from __future__ import annotations

from decimal import Decimal
from datetime import date, timedelta

import pytest

from diet_tracker_server.services.weight_service import (
    MAX_RANGE_DAYS,
    normalize_to_lb,
    validate_range,
)


def test_normalize_passthrough_lb() -> None:
    assert normalize_to_lb(Decimal("180.50"), unit="lb") == Decimal("180.50")


def test_normalize_kg_to_lb() -> None:
    assert normalize_to_lb(Decimal("70"), unit="kg") == Decimal("154.32")


def test_normalize_kg_rounds_half_even() -> None:
    assert normalize_to_lb(Decimal("1"), unit="kg") == Decimal("2.20")


def test_validate_range_accepts_366_days() -> None:
    validate_range(date(2024, 1, 1), date(2024, 1, 1) + timedelta(days=366))


def test_validate_range_rejects_over_366() -> None:
    with pytest.raises(ValueError):
        validate_range(date(2024, 1, 1), date(2024, 1, 1) + timedelta(days=367))


def test_validate_range_rejects_reversed() -> None:
    with pytest.raises(ValueError):
        validate_range(date(2024, 1, 2), date(2024, 1, 1))


def test_max_range_days_constant() -> None:
    assert MAX_RANGE_DAYS == 366
