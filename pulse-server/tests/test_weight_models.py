from __future__ import annotations

from decimal import Decimal

import pytest
from pydantic import ValidationError

from diet_tracker_server.models.weight import WeightEntryUpsert


def test_upsert_accepts_lb() -> None:
    body = WeightEntryUpsert(weight=Decimal("180.5"), unit="lb")
    assert body.weight == Decimal("180.5")
    assert body.unit == "lb"


def test_upsert_accepts_kg() -> None:
    body = WeightEntryUpsert(weight=Decimal("82"), unit="kg")
    assert body.unit == "kg"


def test_upsert_rejects_zero_weight() -> None:
    with pytest.raises(ValidationError):
        WeightEntryUpsert(weight=Decimal("0"), unit="lb")


def test_upsert_rejects_negative_weight() -> None:
    with pytest.raises(ValidationError):
        WeightEntryUpsert(weight=Decimal("-1"), unit="lb")


def test_upsert_rejects_invalid_unit() -> None:
    with pytest.raises(ValidationError):
        WeightEntryUpsert(weight=Decimal("180"), unit="oz")  # type: ignore[arg-type]
