"""Response DTOs for the /activity read endpoints.

Mirrors the Apple-master/Hevy-detail model: a workout summary for the feed,
a full detail with optional linked strength exercises, and the week/month/year
trend summary. Numeric DB columns are typed ``float`` so Pydantic coerces the
``Decimal`` rows to JSON numbers for the Swift client.
"""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from typing import Literal
from uuid import UUID

from pydantic import BaseModel

ActivityPeriod = Literal["week", "month", "year"]

WEIGHTS_ACTIVITY_TYPES: frozenset[str] = frozenset(
    {"TraditionalStrengthTraining", "FunctionalStrengthTraining"}
)
"""Apple activity_type values that belong to the Weights group; everything else is Cardio."""


class StrengthBrief(BaseModel):
    """Compact lifting rollup shown on a feed row for a linked strength workout."""

    exercise_count: int
    set_count: int
    volume_lbs: float


class ActivityWorkoutSummary(BaseModel):
    """One workout as it appears in the chronological feed."""

    id: UUID
    activity_type: str
    start_time: DateTimeValue
    end_time: DateTimeValue
    duration_min: float | None
    active_energy_cal: float | None
    distance_km: float | None
    has_strength_detail: bool
    strength_brief: StrengthBrief | None


class WorkoutFeedPage(BaseModel):
    """A page of feed workouts plus the composite cursor for the next (older) page."""

    items: list[ActivityWorkoutSummary]
    next_before: DateTimeValue | None
    next_before_id: UUID | None


class WorkoutSet(BaseModel):
    """A single Hevy set within an exercise."""

    set_index: int
    set_type: str | None
    weight_lbs: float | None
    reps: int | None
    rpe: float | None
    distance_km: float | None
    duration_seconds: int | None


class WorkoutExercise(BaseModel):
    """One exercise: its sets, set count, total volume, and top set by est-1RM."""

    exercise_title: str
    superset_id: str | None
    set_count: int
    volume_lbs: float
    top_set: WorkoutSet | None
    sets: list[WorkoutSet]


class StrengthTotals(BaseModel):
    """Workout-level lifting totals shown in the detail strength header."""

    exercise_count: int
    set_count: int
    volume_lbs: float


class ActivityWorkoutDetail(BaseModel):
    """Full workout detail: Apple stats plus linked Hevy exercises when present."""

    id: UUID
    activity_type: str
    start_time: DateTimeValue
    end_time: DateTimeValue
    duration_min: float | None
    active_energy_cal: float | None
    basal_energy_cal: float | None
    avg_heart_rate: float | None
    max_heart_rate: float | None
    distance_km: float | None
    elevation_ascended_m: float | None
    step_count: int | None
    flights_climbed: int | None
    avg_mets: float | None
    indoor: bool | None
    exercises: list[WorkoutExercise]
    strength_totals: StrengthTotals | None


class MetricDelta(BaseModel):
    """A metric's current value, the prior period's value, and percent change."""

    current: float
    previous: float
    pct: float | None


class ActivityTotals(BaseModel):
    """Headline totals for a trend period."""

    workout_count: int
    total_duration_min: float
    total_active_energy_cal: float


class ActivityDeltas(BaseModel):
    """Period-over-period deltas for the three headline totals."""

    workout_count: MetricDelta
    total_duration_min: MetricDelta
    total_active_energy_cal: MetricDelta


class TypeBreakdown(BaseModel):
    """One slice of the by-type breakdown (duration share of the period)."""

    activity_type: str
    count: int
    duration_min: float
    share: float


class VolumeBucket(BaseModel):
    """Strength volume + workout time for one sub-bucket of the period."""

    bucket_start: DateValue
    volume_lbs: float
    duration_min: float


class TopLift(BaseModel):
    """A lift's best estimated 1RM in the period, flagged when it's an all-time PR."""

    exercise_title: str
    best_est_1rm: float
    best_weight_lbs: float
    best_reps: int
    date: DateValue
    is_pr: bool


class ActivitySummary(BaseModel):
    """Week/month/year trend summary powering the Trends screen and feed strip.

    ``by_type`` replaces the former ``by_group`` field: both strength activity
    types are collapsed into a single ``"Weights"`` label; every other type maps
    to itself.  ``weeks`` is populated only when ``period == "month"``; ``months``
    is populated only when ``period == "year"``; both default to ``[]`` otherwise.
    """

    period: ActivityPeriod
    period_start: DateValue
    period_end: DateValue
    totals: ActivityTotals
    deltas: ActivityDeltas
    by_type: list[TypeBreakdown]
    weeks: list[WeekRollup] = []
    months: list[MonthRollup] = []
    volume_series: list[VolumeBucket]
    top_lifts: list[TopLift]


class WeekRollup(BaseModel):
    """One Monday-anchored week within a month: clamped bounds, session count,
    total duration, and per-type breakdown."""

    week_start: DateValue
    """Inclusive start of the week, clamped to the enclosing month's bounds."""
    week_end: DateValue
    """Inclusive end of the week, clamped to the enclosing month's bounds."""
    session_count: int
    """Number of workouts that fall in this week."""
    duration_min: float
    """Total workout duration in minutes for this week."""
    by_type: list[TypeBreakdown]
    """Per-breakdown-label duration rollup for this week, sorted duration desc."""


class MonthRollup(BaseModel):
    """One calendar month with session count and total duration totals."""

    month_start: DateValue
    """First day of the month (always day=1)."""
    session_count: int
    """Number of workouts in this month."""
    duration_min: float
    """Total workout duration in minutes for this month."""


class DayGroup(BaseModel):
    """One calendar day in the week drill-down: the day's date and its workouts."""

    date: DateValue
    workouts: list[ActivityWorkoutSummary]


class WeekDetail(BaseModel):
    """Day-grouped workout view for a single Mon-Sun week.

    ``day_groups`` contains only days that have workouts, ordered newest-day first.
    Workouts within each day are also ordered newest-first by ``start_time``.
    """

    week_start: DateValue
    week_end: DateValue
    day_groups: list[DayGroup]


class ActivityTypeSetting(BaseModel):
    """One activity type with its best-effort display name, workout count, and
    effective cardio flag."""

    activity_type: str
    display_name: str
    count: int
    is_cardio: bool


class ActivityTypesResponse(BaseModel):
    """All activity types a user has recorded, with per-type cardio flags,
    sorted by count descending."""

    types: list[ActivityTypeSetting]
