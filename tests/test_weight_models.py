"""Validation tests for the `WeightEntryUpsert` Pydantic model.

Covers acceptance of `lb` and `kg` units, and rejection of zero,
negative, and unsupported-unit inputs.
"""

from __future__ import annotations

from decimal import Decimal

import pytest
from pydantic import ValidationError

from diet_tracker_server.models.weight import WeightEntryUpsert


def test_upsert_accepts_lb() -> None:
    """`WeightEntryUpsert` accepts a positive `lb` weight."""
    body = WeightEntryUpsert(weight=Decimal("180.5"), unit="lb")
    assert body.weight == Decimal("180.5")
    assert body.unit == "lb"


def test_upsert_accepts_kg() -> None:
    """`WeightEntryUpsert` accepts a positive `kg` weight."""
    body = WeightEntryUpsert(weight=Decimal("82"), unit="kg")
    assert body.unit == "kg"


def test_upsert_rejects_zero_weight() -> None:
    """Zero weight fails validation with `ValidationError`."""
    with pytest.raises(ValidationError):
        WeightEntryUpsert(weight=Decimal("0"), unit="lb")


def test_upsert_rejects_negative_weight() -> None:
    """Negative weight fails validation with `ValidationError`."""
    with pytest.raises(ValidationError):
        WeightEntryUpsert(weight=Decimal("-1"), unit="lb")


def test_upsert_rejects_invalid_unit() -> None:
    """A non-`lb`/`kg` unit fails validation with `ValidationError`."""
    with pytest.raises(ValidationError):
        WeightEntryUpsert(weight=Decimal("180"), unit="oz")  # type: ignore[arg-type]
