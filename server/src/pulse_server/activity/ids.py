"""Deterministic UUID5 ids for activity rows, mirroring ``log_ids.py`` so
imports upsert idempotently without a prior read."""

from __future__ import annotations

import uuid
from datetime import datetime as DateTimeValue


def apple_workout_id(user_key: str, start_time: DateTimeValue, activity_type: str) -> str:
    """Stable id for an Apple workout from its owner, start, and activity type.

    **Inputs:**
    - user_key (str): Owning user key.
    - start_time (datetime): Workout start (tz-aware).
    - activity_type (str): Prefix-stripped activity type.

    **Outputs:**
    - str: Canonical UUID5 string.
    """
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{user_key}:{start_time.isoformat()}:{activity_type}"))


def strength_workout_id(user_key: str, title: str, start_time: DateTimeValue) -> str:
    """Stable id for a Hevy session from owner, title, and start.

    **Inputs:**
    - user_key (str): Owning user key.
    - title (str): Hevy workout title.
    - start_time (datetime): Session start (tz-aware).

    **Outputs:**
    - str: Canonical UUID5 string.
    """
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{user_key}:{title}:{start_time.isoformat()}"))


def strength_set_id(workout_id: str, exercise_title: str, set_index: int) -> str:
    """Stable id for a Hevy set within its parent workout.

    **Inputs:**
    - workout_id (str): Parent ``strength_workouts`` id.
    - exercise_title (str): Exercise name.
    - set_index (int): Set ordinal within the exercise.

    **Outputs:**
    - str: Canonical UUID5 string.
    """
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{workout_id}:{exercise_title}:{set_index}"))
