"""Cardio default heuristic: constant set of obvious-cardio Apple Health activity
types and a single override-aware lookup function. No DB access."""

from __future__ import annotations

DEFAULT_CARDIO_TYPES: frozenset[str] = frozenset(
    {
        "Running",
        "Cycling",
        "Swimming",
        "Rowing",
        "Walking",
        "Hiking",
        "Elliptical",
        "StairClimbing",
        "HighIntensityIntervalTraining",
        "Cardio",
        "MixedCardio",
        "CrossTraining",
    }
)
"""Apple Health ``HKWorkoutActivityType`` names (prefix stripped) that are
treated as cardio by default. Matches how ``apple_workouts.activity_type`` is
stored (e.g. ``"Running"``, not ``"HKWorkoutActivityTypeRunning"``)."""


def effective_is_cardio(activity_type: str, overrides: dict[str, bool]) -> bool:
    """Determine whether an activity type counts as cardio, respecting per-type overrides.

    **Inputs:**
    - activity_type (str): The bare Apple Health activity type string
      (e.g. ``"Running"``), as stored in ``apple_workouts.activity_type``.
    - overrides (dict[str, bool]): Caller-supplied per-type overrides. When
      ``activity_type`` is a key here, its value takes unconditional
      precedence over the default set.

    **Outputs:**
    - bool: ``overrides[activity_type]`` when the key is present; otherwise
      ``activity_type in DEFAULT_CARDIO_TYPES``.
    """
    if activity_type in overrides:
        return overrides[activity_type]
    return activity_type in DEFAULT_CARDIO_TYPES
