"""Unit tests for the Hevy CSV parser."""

from __future__ import annotations

from pathlib import Path
from zoneinfo import ZoneInfo

from pulse_server.activity.hevy_parser import parse_hevy_csv

FIXTURE = Path(__file__).parent / "fixtures" / "activity" / "hevy_sample.csv"
TZ = ZoneInfo("America/Toronto")


def test_groups_rows_into_sessions():
    workouts, sets = parse_hevy_csv(FIXTURE, user_key="khash", tz=TZ)
    assert len(workouts) == 2  # Chest Day + Morning Cardio
    assert len(sets) == 3
    titles = {w.title for w in workouts}
    assert titles == {"Chest Day", "Morning Cardio"}


def test_parses_times_in_timezone():
    workouts, _ = parse_hevy_csv(FIXTURE, user_key="khash", tz=TZ)
    chest = next(w for w in workouts if w.title == "Chest Day")
    assert chest.start_time.year == 2026
    assert chest.start_time.hour == 7
    assert chest.start_time.tzinfo is not None
    assert chest.start_time.utcoffset() is not None


def test_blank_numeric_cells_become_none():
    _, sets = parse_hevy_csv(FIXTURE, user_key="khash", tz=TZ)
    stair = next(s for s in sets if s.exercise_title == "Stair Machine (Steps)")
    assert stair.weight_lbs is None
    assert stair.reps is None
    assert stair.duration_seconds == 1206
    warmup = next(s for s in sets if s.set_index == 0 and s.exercise_title == "Incline Dumbbell Press")
    assert warmup.weight_lbs == 55.0
    assert warmup.rpe is None
    normal = next(s for s in sets if s.set_index == 1 and s.exercise_title == "Incline Dumbbell Press")
    assert normal.rpe == 8.0
