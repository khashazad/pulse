"""Unit tests for pure activity trend math."""

from __future__ import annotations

from datetime import date

from pulse_server.services.activity_summary import (
    breakdown_label,
    bucket_volume,
    compute_top_lifts,
    days_in_week,
    est_one_rep_max,
    months_in_year,
    pct_change,
    period_bounds,
    rollup_by_group,
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


def test_rollup_by_group_buckets_and_shares() -> None:
    """Weights/Cardio groups carry share-of-total; subtypes carry share-of-group."""
    rows = [
        {"activity_type": "TraditionalStrengthTraining", "duration_min": 60.0},
        {"activity_type": "FunctionalStrengthTraining", "duration_min": 20.0},
        {"activity_type": "Running", "duration_min": 20.0},
    ]
    out = rollup_by_group(rows, {"TraditionalStrengthTraining", "FunctionalStrengthTraining"})
    by_name = {g.group: g for g in out}
    assert by_name["weights"].duration_min == 80.0
    assert round(by_name["weights"].share, 3) == 0.8  # 80 / 100
    assert round(by_name["cardio"].share, 3) == 0.2
    # subtype share is within its group: strength subtypes sum to ~1.0
    w_subs = {t.activity_type: t.share for t in by_name["weights"].subtypes}
    assert round(w_subs["TraditionalStrengthTraining"], 3) == 0.75  # 60 / 80
    assert by_name["weights"].subtypes[0].activity_type == "TraditionalStrengthTraining"  # desc
    assert out[0].group == "weights"  # larger group leads


def test_rollup_by_group_single_group() -> None:
    """A cardio-only period yields just the cardio group."""
    rows = [{"activity_type": "Running", "duration_min": 30.0}]
    out = rollup_by_group(rows, {"TraditionalStrengthTraining"})
    assert [g.group for g in out] == ["cardio"]
    assert out[0].share == 1.0


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


# ---------------------------------------------------------------------------
# days_in_week
# ---------------------------------------------------------------------------


def test_days_in_week_returns_seven_days_with_counts() -> None:
    """days_in_week returns 7 day dicts Mon-Sun with correct workout counts."""
    week_start = date(2026, 6, 22)  # Monday
    week_end = date(2026, 6, 28)  # Sunday
    rows = [
        # Two workouts on Monday.
        {"local_date": date(2026, 6, 22), "activity_type": "Running", "duration_min": 30.0},
        {"local_date": date(2026, 6, 22), "activity_type": "Cycling", "duration_min": 45.0},
        # One workout on Thursday.
        {"local_date": date(2026, 6, 25), "activity_type": "Running", "duration_min": 35.0},
    ]
    days = days_in_week(rows, week_start, week_end)

    assert len(days) == 7
    assert days[0]["date"] == date(2026, 6, 22)
    assert days[-1]["date"] == date(2026, 6, 28)

    # Monday: 2 workouts, 75 min total.
    assert days[0]["workout_count"] == 2
    assert days[0]["duration_min"] == 75.0

    # Thursday (index 3): 1 workout, 35 min.
    assert days[3]["workout_count"] == 1
    assert days[3]["duration_min"] == 35.0

    # Other days: 0 workouts.
    assert all(days[i]["workout_count"] == 0 for i in range(1, 7) if i != 3)
