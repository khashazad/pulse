"""Unit tests for the streaming Apple Health export parser."""

from __future__ import annotations

from pathlib import Path

from pulse_server.activity.apple_parser import parse_apple_export

FIXTURE = Path(__file__).parent / "fixtures" / "activity" / "apple_sample.xml"


def test_parses_workouts_and_strips_prefix():
    workouts, _ = parse_apple_export(FIXTURE, user_key="khash")
    assert len(workouts) == 2
    types = {w.activity_type for w in workouts}
    assert types == {"TraditionalStrengthTraining", "Yoga"}


def test_full_workout_stats_and_metadata():
    workouts, _ = parse_apple_export(FIXTURE, user_key="khash")
    w = next(w for w in workouts if w.activity_type == "TraditionalStrengthTraining")
    assert w.duration_min == 68.0
    assert w.active_energy_cal == 408.38
    assert w.basal_energy_cal == 154.7
    assert w.avg_heart_rate == 118.2
    assert w.max_heart_rate == 160.0
    assert w.distance_km == 4.82
    assert w.step_count == 320
    assert w.flights_climbed == 3
    assert w.indoor is True
    assert w.avg_mets == 6.5
    assert w.temperature_f == 73.4
    assert w.humidity_pct == 4300.0
    assert w.timezone == "America/Toronto"
    assert w.elevation_ascended_m == 86.52  # 8652 cm
    assert w.route_gpx_path == "/workout-routes/route_2026-06-12_7.26am.gpx"
    assert w.start_time.utcoffset() is not None


def test_minimal_workout_has_none_stats():
    workouts, _ = parse_apple_export(FIXTURE, user_key="khash")
    y = next(w for w in workouts if w.activity_type == "Yoga")
    assert y.active_energy_cal is None
    assert y.avg_heart_rate is None
    assert y.indoor is None
    assert y.route_gpx_path is None


def test_parses_daily_activity_and_ignores_records():
    _, days = parse_apple_export(FIXTURE, user_key="khash")
    assert len(days) == 2  # the <Record> is ignored
    d = next(d for d in days if d.date.isoformat() == "2026-06-12")
    assert d.active_energy_cal == 577.8
    assert d.active_energy_goal == 780.0
    assert d.exercise_minutes == 55
    assert d.exercise_goal == 60
    assert d.stand_hours == 7
    assert d.stand_goal == 12
