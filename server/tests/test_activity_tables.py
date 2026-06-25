"""Unit checks that the activity tables are declared and column-complete.

These guard against drift between schema.sql and the hand-maintained
SQLAlchemy Core definitions for the new activity-import tables.
"""

from __future__ import annotations

from pulse_server.repositories.tables import (
    apple_workouts,
    daily_activity,
    strength_sets,
    strength_workouts,
)


def test_apple_workouts_columns():
    cols = set(apple_workouts.c.keys())
    assert {
        "id", "user_key", "activity_type", "source_name", "start_time",
        "end_time", "duration_min", "active_energy_cal", "basal_energy_cal",
        "avg_heart_rate", "max_heart_rate", "distance_km", "step_count",
        "flights_climbed", "indoor", "elevation_ascended_m", "avg_mets",
        "temperature_f", "humidity_pct", "timezone", "route_gpx_path",
        "linked_strength_workout_id", "created_at",
    } == cols


def test_strength_tables_columns():
    assert {"id", "user_key", "title", "start_time", "end_time",
            "description", "created_at"} == set(strength_workouts.c.keys())
    assert {
        "id", "strength_workout_id", "user_key", "exercise_title",
        "superset_id", "exercise_notes", "set_index", "set_type",
        "weight_lbs", "reps", "distance_km", "duration_seconds", "rpe",
        "created_at",
    } == set(strength_sets.c.keys())


def test_daily_activity_columns():
    assert {
        "user_key", "date", "active_energy_cal", "active_energy_goal",
        "exercise_minutes", "exercise_goal", "stand_hours", "stand_goal",
        "created_at",
    } == set(daily_activity.c.keys())
