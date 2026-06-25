"""Construction/coercion tests for activity response DTOs."""

from __future__ import annotations

from datetime import UTC, datetime
from decimal import Decimal
from uuid import uuid4

from pulse_server.models.activity import (
    ActivityWorkoutSummary,
    MetricDelta,
    WorkoutFeedPage,
)


def test_summary_dto_coerces_decimal_to_float() -> None:
    """A Numeric/Decimal value is accepted and exposed as float on a float-typed field."""
    w = ActivityWorkoutSummary(
        id=uuid4(),
        activity_type="Running",
        start_time=datetime(2026, 6, 24, 18, 0, tzinfo=UTC),
        end_time=datetime(2026, 6, 24, 18, 32, tzinfo=UTC),
        duration_min=Decimal("32.0"),
        active_energy_cal=Decimal("344"),
        distance_km=Decimal("4.1"),
        has_strength_detail=False,
        strength_brief=None,
    )
    assert isinstance(w.duration_min, float)
    assert w.active_energy_cal == 344.0


def test_feed_page_holds_items_and_cursor() -> None:
    """WorkoutFeedPage carries the item list and an optional next_before cursor."""
    page = WorkoutFeedPage(items=[], next_before=None)
    assert page.items == [] and page.next_before is None


def test_metric_delta_allows_null_pct() -> None:
    """MetricDelta.pct is None when there is no prior-period baseline."""
    d = MetricDelta(current=10.0, previous=0.0, pct=None)
    assert d.pct is None
