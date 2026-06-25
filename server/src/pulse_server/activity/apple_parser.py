"""Stream an Apple Health ``export.xml`` into workout and daily-activity value
types. Uses ``iterparse`` and clears each element so the 1.4 GB file never
loads whole. Raw ``<Record>`` samples are skipped."""

from __future__ import annotations

from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from pathlib import Path
from xml.etree.ElementTree import Element, iterparse

from pulse_server.activity.models import AppleWorkout, DailyActivity

_APPLE_TIME_FORMAT = "%Y-%m-%d %H:%M:%S %z"
_WORKOUT_PREFIX = "HKWorkoutActivityType"
_QUANTITY_PREFIX = "HKQuantityTypeIdentifier"


def _require(value: str | None, attr: str) -> str:
    """Return a required XML attribute value, raising if absent.

    **Inputs:**
    - value (str | None): The raw attribute read from the element.
    - attr (str): Attribute name, used in the error message.

    **Outputs:**
    - str: The non-None value.

    **Raises/Throws:**
    - ValueError: If value is None (attribute missing from element).
    """
    if value is None:
        raise ValueError(f"missing required attribute: {attr}")
    return value


def _parse_apple_time(value: str) -> DateTimeValue:
    """Parse an Apple timestamp with explicit offset.

    **Inputs:**
    - value (str): e.g. ``"2026-06-12 07:26:00 -0400"``.

    **Outputs:**
    - datetime: Timezone-aware datetime.
    """
    return DateTimeValue.strptime(value, _APPLE_TIME_FORMAT)


def _leading_number(value: str | None) -> float | None:
    """Extract the leading numeric token from a metadata value.

    Apple metadata values look like ``"73.4 degF"`` or ``"8652 cm"``; this
    returns the number, or None when absent/non-numeric.

    **Inputs:**
    - value (str | None): Raw metadata value.

    **Outputs:**
    - float | None: Leading number, or None.
    """
    if not value:
        return None
    token = value.strip().split(" ", 1)[0]
    try:
        return float(token)
    except ValueError:
        return None


def _build_workout(elem: Element, user_key: str) -> AppleWorkout:
    """Build an ``AppleWorkout`` from a parsed ``<Workout>`` element.

    **Inputs:**
    - elem (Element): The ``<Workout>`` element with its children.
    - user_key (str): Owning user key.

    **Outputs:**
    - AppleWorkout: Populated value type (missing stats become None).
    """
    metadata = {
        m.get("key"): m.get("value") for m in elem.findall("MetadataEntry")
    }
    stats: dict[str, Element] = {
        (s.get("type") or "").removeprefix(_QUANTITY_PREFIX): s
        for s in elem.findall("WorkoutStatistics")
    }

    def stat_sum(name: str) -> float | None:
        s = stats.get(name)
        if s is None:
            return None
        sum_raw = s.get("sum")
        return float(sum_raw) if sum_raw else None

    distance = stat_sum("DistanceWalkingRunning")
    if distance is None:
        distance = stat_sum("DistanceCycling")

    heart = stats.get("HeartRate")
    avg_raw = heart.get("average") if heart is not None else None
    avg_hr = float(avg_raw) if avg_raw else None
    max_raw = heart.get("maximum") if heart is not None else None
    max_hr = float(max_raw) if max_raw else None

    steps = stat_sum("StepCount")
    flights = stat_sum("FlightsClimbed")

    indoor_raw = metadata.get("HKIndoorWorkout")
    indoor = (indoor_raw == "1") if indoor_raw is not None else None

    elevation_cm = _leading_number(metadata.get("HKElevationAscended"))
    elevation_m = elevation_cm / 100.0 if elevation_cm is not None else None

    route_ref = elem.find("WorkoutRoute/FileReference")
    route_path = route_ref.get("path") if route_ref is not None else None

    duration_raw = elem.get("duration")

    return AppleWorkout(
        user_key=user_key,
        activity_type=(elem.get("workoutActivityType") or "").removeprefix(_WORKOUT_PREFIX),
        source_name=elem.get("sourceName"),
        start_time=_parse_apple_time(_require(elem.get("startDate"), "startDate")),
        end_time=_parse_apple_time(_require(elem.get("endDate"), "endDate")),
        duration_min=float(duration_raw) if duration_raw else None,
        active_energy_cal=stat_sum("ActiveEnergyBurned"),
        basal_energy_cal=stat_sum("BasalEnergyBurned"),
        avg_heart_rate=avg_hr,
        max_heart_rate=max_hr,
        distance_km=distance,
        step_count=int(steps) if steps is not None else None,
        flights_climbed=int(flights) if flights is not None else None,
        indoor=indoor,
        elevation_ascended_m=elevation_m,
        avg_mets=_leading_number(metadata.get("HKAverageMETs")),
        temperature_f=_leading_number(metadata.get("HKWeatherTemperature")),
        humidity_pct=_leading_number(metadata.get("HKWeatherHumidity")),
        timezone=metadata.get("HKTimeZone"),
        route_gpx_path=route_path,
    )


def _build_daily(elem: Element, user_key: str) -> DailyActivity:
    """Build a ``DailyActivity`` from an ``<ActivitySummary>`` element.

    **Inputs:**
    - elem (Element): The ``<ActivitySummary>`` element.
    - user_key (str): Owning user key.

    **Outputs:**
    - DailyActivity: Populated value type.
    """
    return DailyActivity(
        user_key=user_key,
        date=DateValue.fromisoformat(_require(elem.get("dateComponents"), "dateComponents")),
        active_energy_cal=float(_require(elem.get("activeEnergyBurned"), "activeEnergyBurned")),
        active_energy_goal=float(_require(elem.get("activeEnergyBurnedGoal"), "activeEnergyBurnedGoal")),
        exercise_minutes=int(float(_require(elem.get("appleExerciseTime"), "appleExerciseTime"))),
        exercise_goal=int(float(_require(elem.get("appleExerciseTimeGoal"), "appleExerciseTimeGoal"))),
        stand_hours=int(float(_require(elem.get("appleStandHours"), "appleStandHours"))),
        stand_goal=int(float(_require(elem.get("appleStandHoursGoal"), "appleStandHoursGoal"))),
    )


def parse_apple_export(
    path: str | Path, *, user_key: str
) -> tuple[list[AppleWorkout], list[DailyActivity]]:
    """Stream an Apple Health export into workouts and daily activity.

    **Inputs:**
    - path (str | Path): Path to ``export.xml``.
    - user_key (str): Owning user key applied to every row.

    **Outputs:**
    - tuple[list[AppleWorkout], list[DailyActivity]]: All workout sessions and
      daily activity summaries; raw samples are ignored.
    """
    workouts: list[AppleWorkout] = []
    days: list[DailyActivity] = []

    for event, elem in iterparse(str(path), events=("end",)):
        if elem.tag == "Workout":
            workouts.append(_build_workout(elem, user_key))
            elem.clear()
        elif elem.tag == "ActivitySummary":
            days.append(_build_daily(elem, user_key))
            elem.clear()
        elif elem.tag == "Record":
            elem.clear()

    return workouts, days
