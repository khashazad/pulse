"""Unit tests for the streaming Apple Health export parser."""

from __future__ import annotations

import tracemalloc
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


def test_streaming_parser_memory_stays_flat(tmp_path: Path) -> None:
    """Guard the streaming invariant: iterparse + root.clear() must not retain
    empty element shells on the document root.

    Without root.clear(), each elem.clear() frees the subtree but leaves the
    shell on the root.  At 100_000 <Record> elements the broken version retains
    ~35-80 MB of empty shells; the fixed version stays well under 4 MB.

    Numbers used:
    - Record count: 100_000  (generates ~27 MB of XML; parses in <3 s)
    - Peak threshold: 4 MB   (fixed code peaks ~0.5-1.5 MB; broken ~35-80 MB)
    The fixed-vs-broken gap is comfortably >10x.
    """
    record_count = 100_000
    peak_threshold_bytes = 4 * 1024 * 1024  # 4 MB

    xml_path = tmp_path / "big_export.xml"
    lines: list[str] = []
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append("<HealthData>")
    # Two workouts so the parser actually exercises _build_workout paths
    for i in range(2):
        lines.append(
            f'<Workout workoutActivityType="HKWorkoutActivityTypeTraditionalStrengthTraining"'
            f' duration="60" sourceName="Test"'
            f' startDate="2026-06-{10 + i:02d} 08:00:00 -0400"'
            f' endDate="2026-06-{10 + i:02d} 09:00:00 -0400">'
            f"</Workout>"
        )
    # One ActivitySummary
    lines.append(
        '<ActivitySummary dateComponents="2026-06-12"'
        ' activeEnergyBurned="400.0" activeEnergyBurnedGoal="780.0"'
        ' appleExerciseTime="30" appleExerciseTimeGoal="60"'
        ' appleStandHours="8" appleStandHoursGoal="12"/>'
    )
    # Many Records — the element type most responsible for shell accumulation
    for i in range(record_count):
        lines.append(
            f'<Record type="HKQuantityTypeIdentifierHeartRate"'
            f' startDate="2026-06-12 08:{(i % 60):02d}:00 -0400"'
            f' endDate="2026-06-12 08:{(i % 60):02d}:01 -0400"'
            f' value="{60 + (i % 40)}"/>'
        )
    lines.append("</HealthData>")

    xml_path.write_text("\n".join(lines), encoding="utf-8")

    tracemalloc.start()
    workouts, days = parse_apple_export(xml_path, user_key="test")
    _current, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()

    # Correctness at scale
    assert len(workouts) == 2
    assert len(days) == 1

    # Bounded memory: peak retained tree must stay well below threshold
    assert peak < peak_threshold_bytes, (
        f"Peak retained memory {peak / 1024 / 1024:.1f} MB exceeded "
        f"{peak_threshold_bytes / 1024 / 1024:.0f} MB — "
        "iterparse root-clearing invariant may be broken"
    )
