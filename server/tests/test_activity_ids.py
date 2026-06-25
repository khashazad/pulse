"""Determinism checks for activity-import UUID5 derivations."""

from __future__ import annotations

from datetime import datetime, timezone

from pulse_server.activity import ids


def test_apple_workout_id_is_deterministic():
    t = datetime(2026, 6, 12, 8, 34, tzinfo=timezone.utc)
    a = ids.apple_workout_id("khash", t, "TraditionalStrengthTraining")
    b = ids.apple_workout_id("khash", t, "TraditionalStrengthTraining")
    assert a == b
    assert len(a) == 36  # canonical UUID string


def test_apple_workout_id_varies_by_input():
    t = datetime(2026, 6, 12, 8, 34, tzinfo=timezone.utc)
    assert ids.apple_workout_id("khash", t, "Yoga") != ids.apple_workout_id(
        "khash", t, "Cycling"
    )


def test_strength_set_id_depends_on_workout_and_index():
    wid = ids.strength_workout_id(
        "khash", "Chest Day", datetime(2026, 6, 12, 7, 26, tzinfo=timezone.utc)
    )
    s0 = ids.strength_set_id(wid, "Incline Dumbbell Press", 0)
    s1 = ids.strength_set_id(wid, "Incline Dumbbell Press", 1)
    assert s0 != s1
    assert s0 == ids.strength_set_id(wid, "Incline Dumbbell Press", 0)
