"""Unit tests for pure activity trend math."""

from __future__ import annotations

from datetime import date

from pulse_server.services.activity_summary import (
    bucket_volume,
    compute_top_lifts,
    est_one_rep_max,
    pct_change,
    period_bounds,
    rollup_by_type,
)


def test_month_buckets_never_predate_period_start() -> None:
    """For a month not starting Monday, every bucket_start is clamped to period_start."""
    # July 2026 starts on a Wednesday; the first ISO-week Monday is 2026-06-29.
    start, end = date(2026, 7, 1), date(2026, 7, 31)
    rows = [{"date": date(2026, 7, 2), "volume_lbs": 100.0, "duration_min": 45.0}]
    buckets = bucket_volume(rows, "month", start, end)
    assert buckets, "expected seeded buckets"
    assert all(b.bucket_start >= start for b in buckets)
    assert buckets[0].bucket_start == start  # the pre-period Monday is clamped to Jul 1
    assert buckets[0].volume_lbs == 100.0  # Jul-2 data still lands in that first bucket


def test_epley_est_1rm() -> None:
    """Epley: 135x8 ≈ 171; 100x1 == 100."""
    assert round(est_one_rep_max(135, 8), 1) == 171.0
    assert est_one_rep_max(100, 1) == 100.0


def test_pct_change_handles_zero_baseline() -> None:
    """pct_change is None when previous is 0, else the signed fraction."""
    assert pct_change(10, 0) is None
    assert pct_change(120, 100) == 0.2


def test_week_bounds_monday_to_sunday() -> None:
    """A week period spans Monday..Sunday containing the anchor."""
    start, end = period_bounds("week", date(2026, 6, 24))  # a Wednesday
    assert start == date(2026, 6, 22) and end == date(2026, 6, 28)


def test_rollup_caps_to_top_n_with_other() -> None:
    """rollup_by_type keeps the top N by duration and buckets the rest as Other."""
    rows = [{"activity_type": f"T{i}", "duration_min": float(10 - i)} for i in range(7)]
    out = rollup_by_type(rows, top_n=5)
    assert len(out) == 6  # 5 + Other
    assert out[-1].activity_type == "Other"
    assert round(sum(t.share for t in out), 5) == 1.0


def test_top_lifts_flags_pr_against_history() -> None:
    """A period best beating all prior est-1RM is a PR; otherwise not."""
    history = [
        {"exercise_title": "Bench", "weight_lbs": 135, "reps": 8, "date": date(2026, 6, 1)},
        {"exercise_title": "Bench", "weight_lbs": 155, "reps": 6, "date": date(2026, 6, 24)},
    ]
    lifts = compute_top_lifts(history, period_start=date(2026, 6, 22))
    bench = next(lift for lift in lifts if lift.exercise_title == "Bench")
    assert bench.is_pr is True and bench.best_weight_lbs == 155.0
