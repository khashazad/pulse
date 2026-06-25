"""Plain value types emitted by the activity parsers and consumed by the
activity repository. Decoupled from both file formats and the DB layer."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date as DateValue
from datetime import datetime as DateTimeValue


@dataclass(frozen=True)
class AppleWorkout:
    """One Apple Health ``<Workout>`` session summary."""

    user_key: str
    activity_type: str
    source_name: str | None
    start_time: DateTimeValue
    end_time: DateTimeValue
    duration_min: float | None
    active_energy_cal: float | None
    basal_energy_cal: float | None
    avg_heart_rate: float | None
    max_heart_rate: float | None
    distance_km: float | None
    step_count: int | None
    flights_climbed: int | None
    indoor: bool | None
    elevation_ascended_m: float | None
    avg_mets: float | None
    temperature_f: float | None
    humidity_pct: float | None
    timezone: str | None
    route_gpx_path: str | None


@dataclass(frozen=True)
class DailyActivity:
    """One Apple Health ``<ActivitySummary>`` day."""

    user_key: str
    date: DateValue
    active_energy_cal: float
    active_energy_goal: float
    exercise_minutes: int
    exercise_goal: int
    stand_hours: int
    stand_goal: int


@dataclass(frozen=True)
class StrengthWorkout:
    """A Hevy session header (one per ``(title, start_time)``)."""

    user_key: str
    title: str
    start_time: DateTimeValue
    end_time: DateTimeValue
    description: str | None


@dataclass(frozen=True)
class StrengthSet:
    """One Hevy set, carrying its parent ``strength_workouts`` id (derived by
    the parser) so the repository can set the FK without re-deriving it."""

    user_key: str
    strength_workout_id: str
    exercise_title: str
    superset_id: str | None
    exercise_notes: str | None
    set_index: int
    set_type: str | None
    weight_lbs: float | None
    reps: int | None
    distance_km: float | None
    duration_seconds: int | None
    rpe: float | None
