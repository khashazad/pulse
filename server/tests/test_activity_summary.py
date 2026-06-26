"""Unit tests for pure activity trend math."""

from __future__ import annotations

from datetime import date

import pytest

from pulse_server.services.activity_summary import (
    breakdown_label,
    bucket_volume,
    compute_top_lifts,
    energy_balance,
    est_one_rep_max,
    months_in_year,
    pct_change,
    period_bounds,
    rollup_by_type,
    weeks_in_month,
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


def test_top_lifts_flags_pr_against_history() -> None:
    """A period best beating all prior est-1RM is a PR; otherwise not."""
    history = [
        {"exercise_title": "Bench", "weight_lbs": 135, "reps": 8, "date": date(2026, 6, 1)},
        {"exercise_title": "Bench", "weight_lbs": 155, "reps": 6, "date": date(2026, 6, 24)},
    ]
    lifts = compute_top_lifts(history, period_start=date(2026, 6, 22))
    bench = next(lift for lift in lifts if lift.exercise_title == "Bench")
    assert bench.is_pr is True and bench.best_weight_lbs == 155.0


# ---------------------------------------------------------------------------
# breakdown_label
# ---------------------------------------------------------------------------


def test_breakdown_label_maps_strength_to_weights() -> None:
    """Both strength activity types map to 'Weights'; all others pass through unchanged."""
    assert breakdown_label("TraditionalStrengthTraining") == "Weights"
    assert breakdown_label("FunctionalStrengthTraining") == "Weights"
    assert breakdown_label("Running") == "Running"
    assert breakdown_label("Cycling") == "Cycling"


# ---------------------------------------------------------------------------
# rollup_by_type
# ---------------------------------------------------------------------------


def test_rollup_by_type_merges_strength_types_and_computes_shares() -> None:
    """Both strength types collapse into one 'Weights' row; shares reflect total duration."""
    rows = [
        {"activity_type": "TraditionalStrengthTraining", "duration_min": 60.0},
        {"activity_type": "FunctionalStrengthTraining", "duration_min": 30.0},
        {"activity_type": "Running", "duration_min": 30.0},
    ]
    out = rollup_by_type(rows)
    by_label = {t.activity_type: t for t in out}

    # Both strength types merge into one "Weights" row.
    assert set(by_label.keys()) == {"Weights", "Running"}

    weights = by_label["Weights"]
    assert weights.count == 2
    assert weights.duration_min == 90.0
    assert round(weights.share, 6) == round(90 / 120, 6)

    running = by_label["Running"]
    assert running.count == 1
    assert running.duration_min == 30.0
    assert round(running.share, 6) == round(30 / 120, 6)

    # Sorted desc by duration → Weights leads.
    assert out[0].activity_type == "Weights"


def test_rollup_by_type_empty_rows() -> None:
    """Empty input returns an empty list."""
    assert rollup_by_type([]) == []


# ---------------------------------------------------------------------------
# weeks_in_month
# ---------------------------------------------------------------------------


def test_weeks_in_month_clamps_first_week_and_buckets_by_type() -> None:
    """July 2026 starts Wednesday: first week_start is clamped to Jul 1 (not Jun 29).

    Seeds one Running on Jul 1 and one strength workout on Jul 7 (week 2).
    Verifies clamped bounds, per-week session counts, and by_type sub-breakdown.
    """
    # July 2026: Jul 1 = Wednesday, so first ISO Monday is Jun 29.
    month_start = date(2026, 7, 1)
    month_end = date(2026, 7, 31)
    rows = [
        {"local_date": date(2026, 7, 1), "activity_type": "Running", "duration_min": 30.0},
        {
            "local_date": date(2026, 7, 7),
            "activity_type": "TraditionalStrengthTraining",
            "duration_min": 60.0,
        },
    ]
    weeks = weeks_in_month(rows, month_start, month_end)

    # July 2026 spans 5 ISO weeks (Jun 29-Aug 2 clamps to Jul 1-Jul 31).
    assert len(weeks) == 5

    # First week is clamped to the month start, not the preceding Monday.
    assert weeks[0].week_start == date(2026, 7, 1)
    assert weeks[0].week_end == date(2026, 7, 5)
    assert weeks[0].session_count == 1
    assert weeks[0].duration_min == 30.0
    # by_type for first week: one Running
    assert len(weeks[0].by_type) == 1
    assert weeks[0].by_type[0].activity_type == "Running"

    # Second week: Jul 6-12, contains the strength workout (Jul 7).
    assert weeks[1].week_start == date(2026, 7, 6)
    assert weeks[1].week_end == date(2026, 7, 12)
    assert weeks[1].session_count == 1
    assert weeks[1].duration_min == 60.0
    # by_type: "Weights" (label for TraditionalStrengthTraining)
    assert len(weeks[1].by_type) == 1
    assert weeks[1].by_type[0].activity_type == "Weights"

    # Last week is clamped to month end.
    assert weeks[-1].week_end == date(2026, 7, 31)

    # Weeks with no activity have zero session_count.
    assert all(w.session_count == 0 for w in weeks[2:])


# ---------------------------------------------------------------------------
# months_in_year
# ---------------------------------------------------------------------------


def test_months_in_year_returns_twelve_entries_with_correct_counts() -> None:
    """months_in_year returns exactly 12 MonthRollup entries; populated months have correct totals."""
    rows = [
        {"local_date": date(2026, 6, 24), "activity_type": "Running", "duration_min": 40.0},
        {"local_date": date(2026, 6, 25), "activity_type": "Cycling", "duration_min": 50.0},
    ]
    rollups = months_in_year(rows, 2026)

    assert len(rollups) == 12

    # month_start values cover every month in 2026.
    starts = [r.month_start for r in rollups]
    assert starts[0] == date(2026, 1, 1)
    assert starts[5] == date(2026, 6, 1)
    assert starts[11] == date(2026, 12, 1)

    # June (index 5) has 2 sessions and 90 min.
    june = rollups[5]
    assert june.session_count == 2
    assert june.duration_min == 90.0

    # All other months are empty.
    assert all(r.session_count == 0 for i, r in enumerate(rollups) if i != 5)


def test_months_in_year_through_month_excludes_future_months() -> None:
    """months_in_year emits only Jan..through_month; later months are omitted entirely."""
    rows = [
        {"local_date": date(2026, 3, 10), "activity_type": "Running", "duration_min": 40.0},
        # A row in a future month (relative to the cutoff) must be ignored, not bucketed.
        {"local_date": date(2026, 9, 1), "activity_type": "Cycling", "duration_min": 50.0},
    ]
    rollups = months_in_year(rows, 2026, through_month=6)

    assert len(rollups) == 6
    starts = [r.month_start for r in rollups]
    assert starts[0] == date(2026, 1, 1)
    assert starts[-1] == date(2026, 6, 1)
    # March counted; September dropped (past the cutoff).
    assert rollups[2].session_count == 1
    assert sum(r.session_count for r in rollups) == 1


# ---------------------------------------------------------------------------
# energy_balance
# ---------------------------------------------------------------------------


def test_energy_balance_full_bucket() -> None:
    """Full data bucket: hand-verify intake avg, cardio sum, weight endpoints, maintenance.

    Bucket: 2026-06-01 → 2026-06-07.
    - 3 logged days (2000 + 2200 + 1800 = 6000 kcal); intake_cal_per_day = 2000.0
    - 2 cardio days: 300 + 250 = 550.0 kcal total
    - weight_start = 180.0 (Jun 1, dist 0); weight_end = 178.0 (Jun 7, dist 0)
    - weight_delta_lb = -2.0; weight_span_days = 6
    - est_maintenance_per_day = 2000.0 - (-2.0 * 3500 / 6) ≈ 3166.667
    """
    bucket = (date(2026, 6, 1), date(2026, 6, 7), "Week 1")
    intake = {date(2026, 6, 1): 2000, date(2026, 6, 2): 2200, date(2026, 6, 3): 1800}
    cardio = {date(2026, 6, 1): 300.0, date(2026, 6, 4): 250.0}
    weights = [(date(2026, 6, 1), 180.0), (date(2026, 6, 7), 178.0)]

    result = energy_balance([bucket], intake, cardio, weights)
    assert len(result) == 1
    b = result[0]

    assert b.bucket_start == date(2026, 6, 1)
    assert b.bucket_end == date(2026, 6, 7)
    assert b.label == "Week 1"
    assert b.intake_cal_per_day == pytest.approx(2000.0)
    assert b.cardio_cal_total == pytest.approx(550.0)
    assert b.weight_start == pytest.approx(180.0)
    assert b.weight_end == pytest.approx(178.0)
    assert b.weight_delta_lb == pytest.approx(-2.0)
    assert b.weight_span_days == 6
    expected_maintenance = 2000.0 - (-2.0 * 3500 / 6)
    assert b.est_maintenance_per_day == pytest.approx(expected_maintenance)


def test_energy_balance_weight_readings_outside_bucket_within_fallback() -> None:
    """Weight readings outside the bucket but within ±7 days are used; span from their dates.

    Bucket: 2026-06-10 → 2026-06-16.
    - Jun 4 reading (181.0): 6 days before start, within the start-7d=Jun 3 lower bound → used as w_start.
    - Jun 20 reading (179.0): 4 days after end, within the end+7d=Jun 23 upper bound → used as w_end.
    - weight_span_days = (Jun 20 - Jun 4).days = 16
    """
    bucket = (date(2026, 6, 10), date(2026, 6, 16), "Week 2")
    intake = {date(2026, 6, 11): 2100, date(2026, 6, 12): 1900}
    cardio: dict[date, float] = {}
    weights = [(date(2026, 6, 4), 181.0), (date(2026, 6, 20), 179.0)]

    result = energy_balance([bucket], intake, cardio, weights)
    b = result[0]

    assert b.weight_start == pytest.approx(181.0)
    assert b.weight_end == pytest.approx(179.0)
    assert b.weight_delta_lb == pytest.approx(-2.0)
    assert b.weight_span_days == 16
    assert b.est_maintenance_per_day is not None


def test_energy_balance_single_weight_reading_yields_none_weight_fields() -> None:
    """A single weight reading (same date for w_start and w_end) → weight + maintenance all None."""
    bucket = (date(2026, 6, 10), date(2026, 6, 16), "Week 2")
    intake = {date(2026, 6, 12): 2000}
    cardio = {date(2026, 6, 12): 300.0}
    weights = [(date(2026, 6, 12), 180.0)]

    result = energy_balance([bucket], intake, cardio, weights)
    b = result[0]

    assert b.weight_start is None
    assert b.weight_end is None
    assert b.weight_delta_lb is None
    assert b.weight_span_days is None
    assert b.est_maintenance_per_day is None
    # Intake and cardio are still computed.
    assert b.intake_cal_per_day == pytest.approx(2000.0)
    assert b.cardio_cal_total == pytest.approx(300.0)


def test_energy_balance_no_logged_intake() -> None:
    """No intake logged → intake_cal_per_day and est_maintenance_per_day are None; cardio still sums."""
    bucket = (date(2026, 6, 1), date(2026, 6, 7), "Week 1")
    intake: dict[date, int] = {}
    cardio = {date(2026, 6, 1): 300.0, date(2026, 6, 2): 200.0}
    weights = [(date(2026, 6, 1), 180.0), (date(2026, 6, 7), 178.0)]

    result = energy_balance([bucket], intake, cardio, weights)
    b = result[0]

    assert b.intake_cal_per_day is None
    assert b.est_maintenance_per_day is None
    assert b.cardio_cal_total == pytest.approx(500.0)


def test_energy_balance_zero_data() -> None:
    """No data at all → intake/weight/maintenance None; cardio is 0.0."""
    bucket = (date(2026, 6, 1), date(2026, 6, 7), "Week 1")

    result = energy_balance([bucket], {}, {}, [])
    b = result[0]

    assert b.intake_cal_per_day is None
    assert b.cardio_cal_total == 0.0
    assert b.weight_start is None
    assert b.weight_end is None
    assert b.weight_delta_lb is None
    assert b.weight_span_days is None
    assert b.est_maintenance_per_day is None
