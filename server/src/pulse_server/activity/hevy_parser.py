"""Parse a Hevy CSV export into strength-workout and strength-set value types."""

from __future__ import annotations

import csv
from datetime import datetime as DateTimeValue
from datetime import tzinfo
from pathlib import Path

from pulse_server.activity.models import StrengthSet, StrengthWorkout

_HEVY_TIME_FORMAT = "%d %b %Y, %H:%M"


def _opt_float(value: str | None) -> float | None:
    """Convert a possibly-blank CSV cell to float or None.

    **Inputs:**
    - value (str | None): Raw cell text.

    **Outputs:**
    - float | None: Parsed float, or None when blank/missing.
    """
    if value is None or value.strip() == "":
        return None
    return float(value)


def _opt_int(value: str | None) -> int | None:
    """Convert a possibly-blank CSV cell to int or None.

    **Inputs:**
    - value (str | None): Raw cell text.

    **Outputs:**
    - int | None: Parsed int, or None when blank/missing.
    """
    f = _opt_float(value)
    return None if f is None else int(f)


def _parse_time(value: str, tz: tzinfo) -> DateTimeValue:
    """Parse a Hevy local timestamp and attach the configured timezone.

    **Inputs:**
    - value (str): Timestamp like ``"12 Jun 2026, 08:34"``.
    - tz (tzinfo): Timezone the local time is interpreted in.

    **Outputs:**
    - datetime: Timezone-aware datetime.
    """
    return DateTimeValue.strptime(value, _HEVY_TIME_FORMAT).replace(tzinfo=tz)


def parse_hevy_csv(
    path: str | Path, *, user_key: str, tz: tzinfo
) -> tuple[list[StrengthWorkout], list[StrengthSet]]:
    """Parse a Hevy CSV export into deduplicated workouts and their sets.

    Rows sharing ``(title, start_time)`` collapse to one ``StrengthWorkout``;
    every row yields one ``StrengthSet``.

    **Inputs:**
    - path (str | Path): Path to the Hevy CSV export.
    - user_key (str): Owning user key applied to every emitted row.
    - tz (tzinfo): Timezone for interpreting Hevy local timestamps.

    **Outputs:**
    - tuple[list[StrengthWorkout], list[StrengthSet]]: Deduplicated session
      headers and the flat list of sets.
    """
    workouts: dict[tuple[str, DateTimeValue], StrengthWorkout] = {}
    sets: list[StrengthSet] = []

    with open(path, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            title = row["title"]
            start = _parse_time(row["start_time"], tz)
            end = _parse_time(row["end_time"], tz)
            key = (title, start)
            if key not in workouts:
                description = row.get("description") or None
                workouts[key] = StrengthWorkout(
                    user_key=user_key,
                    title=title,
                    start_time=start,
                    end_time=end,
                    description=description.strip() or None if description else None,
                )
            sets.append(
                StrengthSet(
                    user_key=user_key,
                    workout_title=title,
                    workout_start_time=start,
                    exercise_title=row["exercise_title"],
                    superset_id=(row.get("superset_id") or "").strip() or None,
                    exercise_notes=(row.get("exercise_notes") or "").strip() or None,
                    set_index=int(row["set_index"]),
                    set_type=(row.get("set_type") or "").strip() or None,
                    weight_lbs=_opt_float(row.get("weight_lbs")),
                    reps=_opt_int(row.get("reps")),
                    distance_km=_opt_float(row.get("distance_km")),
                    duration_seconds=_opt_int(row.get("duration_seconds")),
                    rpe=_opt_float(row.get("rpe")),
                )
            )

    return list(workouts.values()), sets
