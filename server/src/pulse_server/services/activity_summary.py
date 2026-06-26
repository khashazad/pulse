"""Pure trend math for activity summaries: est-1RM, period bounds, by-type
rollup, PR-aware top lifts, and volume bucketing. No DB access."""

from __future__ import annotations

import calendar
from datetime import date as DateValue
from datetime import timedelta as TimeDeltaValue

from pulse_server.models.activity import (
    WEIGHTS_ACTIVITY_TYPES,
    ActivityPeriod,
    EnergyBalanceBucket,
    MonthRollup,
    TopLift,
    TypeBreakdown,
    VolumeBucket,
    WeekRollup,
)


def est_one_rep_max(weight_lbs: float, reps: int) -> float:
    """Estimate a one-rep max via the Epley formula.

    When ``reps`` is 1 the set is already a 1RM attempt, so the weight
    is returned directly. For reps > 1 the Epley formula applies.

    **Inputs:**
    - weight_lbs (float): Weight lifted.
    - reps (int): Repetitions performed (>= 1).

    **Outputs:**
    - float: Estimated 1RM. Returns ``weight_lbs`` unchanged when reps <= 1,
      otherwise ``weight * (1 + reps/30)``.
    """
    if reps <= 1:
        return weight_lbs
    return weight_lbs * (1 + reps / 30)


def pct_change(current: float, previous: float) -> float | None:
    """Signed fractional change from previous to current.

    **Inputs:**
    - current (float): Current-period value.
    - previous (float): Prior-period value.

    **Outputs:**
    - float | None: ``(current - previous) / previous``, or None when previous is 0.
    """
    if previous == 0:
        return None
    return (current - previous) / previous


def period_bounds(period: ActivityPeriod, anchor: DateValue) -> tuple[DateValue, DateValue]:
    """Inclusive start/end dates of the period containing ``anchor``.

    **Inputs:**
    - period (ActivityPeriod): ``"week"`` (Mon-Sun), ``"month"``, or ``"year"``.
    - anchor (date): Date the period must contain.

    **Outputs:**
    - tuple[date, date]: ``(start, end)`` inclusive.
    """
    if period == "week":
        start = anchor - TimeDeltaValue(days=anchor.weekday())
        return start, start + TimeDeltaValue(days=6)
    if period == "month":
        start = anchor.replace(day=1)
        end = start.replace(day=calendar.monthrange(start.year, start.month)[1])
        return start, end
    return DateValue(anchor.year, 1, 1), DateValue(anchor.year, 12, 31)


def previous_bounds(period: ActivityPeriod, anchor: DateValue) -> tuple[DateValue, DateValue]:
    """Inclusive bounds of the period immediately before ``anchor``'s period.

    **Inputs:**
    - period (ActivityPeriod): Period granularity.
    - anchor (date): Date in the current period.

    **Outputs:**
    - tuple[date, date]: ``(start, end)`` of the prior period.
    """
    start, _ = period_bounds(period, anchor)
    return period_bounds(period, start - TimeDeltaValue(days=1))


def compute_top_lifts(
    history: list[dict], period_start: DateValue, limit: int = 8
) -> list[TopLift]:
    """Best est-1RM per lift within the period, flagged when it beats all prior history.

    **Inputs:**
    - history (list[dict]): All sets up to the period end, each with
      ``exercise_title``, ``weight_lbs``, ``reps``, ``date``.
    - period_start (date): Start of the current period; sets on/after this are "in period".
    - limit (int): Max lifts to return (highest est-1RM first).

    **Outputs:**
    - list[TopLift]: One entry per lift that has an in-period set, sorted desc by
      best in-period est-1RM, ``is_pr`` true when that beats the prior all-time best.
    """
    prior_best: dict[str, float] = {}
    in_period: dict[str, dict] = {}
    for r in history:
        if not r["weight_lbs"] or not r["reps"]:
            continue
        e1rm = est_one_rep_max(float(r["weight_lbs"]), int(r["reps"]))
        title = r["exercise_title"]
        if r["date"] < period_start:
            prior_best[title] = max(prior_best.get(title, 0.0), e1rm)
        else:
            best = in_period.get(title)
            if best is None or e1rm > best["e1rm"]:
                in_period[title] = {
                    "e1rm": e1rm,
                    "weight": float(r["weight_lbs"]),
                    "reps": int(r["reps"]),
                    "date": r["date"],
                }
    lifts = [
        TopLift(
            exercise_title=title,
            best_est_1rm=v["e1rm"],
            best_weight_lbs=v["weight"],
            best_reps=v["reps"],
            date=v["date"],
            is_pr=v["e1rm"] > prior_best.get(title, 0.0),
        )
        for title, v in in_period.items()
    ]
    lifts.sort(key=lambda t: t.best_est_1rm, reverse=True)
    return lifts[:limit]


def bucket_volume(
    rows: list[dict], period: ActivityPeriod, period_start: DateValue, period_end: DateValue
) -> list[VolumeBucket]:
    """Sum strength volume and workout minutes into sub-buckets of the period.

    Buckets are days for ``week``, ISO weeks (Mon) for ``month``, and months for
    ``year``. Empty buckets are included with zeros so the chart axis is continuous.

    **Inputs:**
    - rows (list[dict]): Rows with ``date`` (date), ``volume_lbs`` (float),
      ``duration_min`` (float).
    - period (ActivityPeriod): Period granularity.
    - period_start (date): Inclusive period start.
    - period_end (date): Inclusive period end.

    **Outputs:**
    - list[VolumeBucket]: Ordered buckets covering the period. Each
      ``bucket_start`` is clamped to ``period_start`` so no bucket is labelled
      before the period (the first month bucket's ISO-week Monday can fall in the
      prior month).
    """

    def bucket_key(d: DateValue) -> DateValue:
        """Map a date to its bucket's start date for the current period.

        **Inputs:**
        - d (date): The date to bucket.

        **Outputs:**
        - date: ``d`` itself for ``week``, the ISO-week Monday for ``month``, or
          the first of the month for ``year``.
        """
        if period == "week":
            return d
        if period == "month":
            return d - TimeDeltaValue(days=d.weekday())
        return d.replace(day=1)

    buckets: dict[DateValue, list[float]] = {}
    # seed empty buckets
    cursor = bucket_key(period_start)
    while cursor <= period_end:
        buckets.setdefault(cursor, [0.0, 0.0])
        if period == "week":
            cursor += TimeDeltaValue(days=1)
        elif period == "month":
            cursor += TimeDeltaValue(days=7)
        else:
            nxt_month = cursor.month % 12 + 1
            nxt_year = cursor.year + (1 if cursor.month == 12 else 0)
            cursor = cursor.replace(year=nxt_year, month=nxt_month, day=1)
    for r in rows:
        b = buckets.setdefault(bucket_key(r["date"]), [0.0, 0.0])
        b[0] += float(r["volume_lbs"] or 0)
        b[1] += float(r["duration_min"] or 0)
    return [
        VolumeBucket(bucket_start=max(k, period_start), volume_lbs=v[0], duration_min=v[1])
        for k, v in sorted(buckets.items())
    ]


# ---------------------------------------------------------------------------
# Per-type rollup math (by_type breakdown — replaces the former by_group layer)
# ---------------------------------------------------------------------------


def breakdown_label(activity_type: str) -> str:
    """Map an Apple Health activity type to its display-level breakdown label.

    Both strength types (``TraditionalStrengthTraining`` and
    ``FunctionalStrengthTraining``) are collapsed into the single label
    ``"Weights"``; all other types pass through unchanged so the iOS layer
    can apply its own display-name mapping.

    **Inputs:**
    - activity_type (str): Raw Apple Health ``activity_type`` string.

    **Outputs:**
    - str: ``"Weights"`` for either strength type, or ``activity_type`` unchanged.
    """
    return "Weights" if activity_type in WEIGHTS_ACTIVITY_TYPES else activity_type


def rollup_by_type(rows: list[dict]) -> list[TypeBreakdown]:
    """Aggregate workout rows by breakdown label, compute duration shares, and sort desc.

    Both strength activity types are merged under the ``"Weights"`` label via
    :func:`breakdown_label`; every other type maps to itself.  The ``share``
    field on each entry is that label's fraction of the total duration across
    all rows.  An empty ``rows`` list returns an empty list.

    **Inputs:**
    - rows (list[dict]): Each dict must have ``activity_type`` (str) and
      ``duration_min`` (float | None) keys.

    **Outputs:**
    - list[TypeBreakdown]: One entry per distinct breakdown label, sorted by
      ``duration_min`` descending.  Each entry's ``share`` is its fraction of
      the total duration (0-1).
    """
    durations: dict[str, float] = {}
    counts: dict[str, int] = {}
    for r in rows:
        label = breakdown_label(r["activity_type"])
        durations[label] = durations.get(label, 0.0) + float(r["duration_min"] or 0)
        counts[label] = counts.get(label, 0) + 1
    if not durations:
        return []
    total = sum(durations.values()) or 1.0
    out = [
        TypeBreakdown(
            activity_type=label,
            count=counts[label],
            duration_min=dur,
            share=dur / total,
        )
        for label, dur in durations.items()
    ]
    out.sort(key=lambda t: t.duration_min, reverse=True)
    return out


def weeks_in_month(
    rows: list[dict],
    month_start: DateValue,
    month_end: DateValue,
) -> list[WeekRollup]:
    """Bucket workout rows into Monday-anchored weeks within a calendar month.

    Weeks are clamped to ``[month_start, month_end]``; the first week's
    ``week_start`` is ``month_start`` even when the ISO Monday falls in the
    prior month.  Weeks with no activity are included with zeros so the chart
    axis is continuous.

    Each ``WeekRollup.by_type`` is the :func:`rollup_by_type` over that week's
    rows, so both strength types collapse into ``"Weights"``.

    **Inputs:**
    - rows (list[dict]): Each dict must have ``local_date`` (date),
      ``activity_type`` (str), and ``duration_min`` (float | None) keys.
      Only rows whose ``local_date`` falls inside ``[month_start, month_end]``
      are considered.
    - month_start (date): First day of the month (inclusive lower bound).
    - month_end (date): Last day of the month (inclusive upper bound).

    **Outputs:**
    - list[WeekRollup]: One entry per Monday-anchored week that overlaps the
      month, ordered chronologically.  ``week_start`` and ``week_end`` are
      clamped to ``[month_start, month_end]``.
    """
    # ISO Monday at or before month_start.
    first_monday = month_start - TimeDeltaValue(days=month_start.weekday())

    # All real-Monday anchors that have any overlap with the month.
    week_mondays: list[DateValue] = []
    cursor = first_monday
    while cursor <= month_end:
        week_mondays.append(cursor)
        cursor += TimeDeltaValue(days=7)

    # Bucket rows by their ISO-week Monday.
    bucket: dict[DateValue, list[dict]] = {m: [] for m in week_mondays}
    for r in rows:
        d: DateValue = r["local_date"]
        if month_start <= d <= month_end:
            monday = d - TimeDeltaValue(days=d.weekday())
            if monday in bucket:
                bucket[monday].append(r)

    out: list[WeekRollup] = []
    for monday in week_mondays:
        week_rows = bucket[monday]
        week_end_raw = monday + TimeDeltaValue(days=6)
        out.append(
            WeekRollup(
                week_start=max(monday, month_start),
                week_end=min(week_end_raw, month_end),
                session_count=len(week_rows),
                duration_min=sum(float(r["duration_min"] or 0) for r in week_rows),
                by_type=rollup_by_type(week_rows),
            )
        )
    return out


def months_in_year(rows: list[dict], year: int) -> list[MonthRollup]:
    """Bucket workout rows by calendar month for a full year, including zero months.

    All twelve months are always present in the output; months with no activity
    have ``session_count=0`` and ``duration_min=0.0``.  Rows whose
    ``local_date`` falls outside ``year`` are silently ignored.

    **Inputs:**
    - rows (list[dict]): Each dict must have ``local_date`` (date),
      ``activity_type`` (str), and ``duration_min`` (float | None) keys.
    - year (int): The calendar year to roll up.

    **Outputs:**
    - list[MonthRollup]: Twelve entries, one per month Jan-Dec, ordered
      chronologically.
    """
    monthly: dict[int, list[dict]] = {m: [] for m in range(1, 13)}
    for r in rows:
        d: DateValue = r["local_date"]
        if d.year == year:
            monthly[d.month].append(r)
    return [
        MonthRollup(
            month_start=DateValue(year, month, 1),
            session_count=len(monthly[month]),
            duration_min=sum(float(r["duration_min"] or 0) for r in monthly[month]),
        )
        for month in range(1, 13)
    ]


# ---------------------------------------------------------------------------
# Energy-balance math (pure; no DB)
# ---------------------------------------------------------------------------


def _weight_endpoints(
    readings: list[tuple[DateValue, float]],
    start: DateValue,
    end: DateValue,
) -> tuple[tuple[DateValue, float] | None, tuple[DateValue, float] | None]:
    """Find the nearest weight readings to each boundary of a bucket.

    ``w_start`` is chosen from readings whose date falls in ``[start - 7d, end]``,
    picking the one closest to ``start``; ties break to the earlier date.
    ``w_end`` is chosen from readings whose date falls in ``[start, end + 7d]``,
    picking the one closest to ``end``; ties break to the later date.

    **Args:**
    - readings (list[tuple[date, float]]): All weight readings as ``(date, weight_lb)``
      pairs, in any order.
    - start (date): Inclusive start of the bucket.
    - end (date): Inclusive end of the bucket.

    **Returns:**
    - tuple[tuple[date, float] | None, tuple[date, float] | None]: ``(w_start, w_end)``
      where each is ``(date, weight_lb)`` or ``None`` when no eligible reading exists.

    **Raises:**
    - Nothing. Returns ``(None, None)`` when the readings list is empty.
    """
    seven = TimeDeltaValue(days=7)

    start_candidates = [r for r in readings if start - seven <= r[0] <= end]
    end_candidates = [r for r in readings if start <= r[0] <= end + seven]

    w_start: tuple[DateValue, float] | None = None
    if start_candidates:
        # Closest to start; ties → earlier date (ascending by date = natural min).
        w_start = min(start_candidates, key=lambda r: (abs((r[0] - start).days), r[0]))

    w_end: tuple[DateValue, float] | None = None
    if end_candidates:
        # Closest to end; ties → later date (negate ordinal so later comes first).
        w_end = min(
            end_candidates,
            key=lambda r: (abs((r[0] - end).days), -r[0].toordinal()),
        )

    return w_start, w_end


def energy_balance(
    buckets: list[tuple[DateValue, DateValue, str]],
    intake_by_day: dict[DateValue, int],
    cardio_by_day: dict[DateValue, float],
    weight_readings: list[tuple[DateValue, float]],
) -> list[EnergyBalanceBucket]:
    """Combine per-day nutrition, cardio, and weight readings into per-bucket energy-balance
    figures.

    For each bucket ``(start, end, label)`` the function computes:

    - **intake_cal_per_day**: average daily calories across days with a logged entry
      in ``[start, end]``; ``None`` if no days were logged.
    - **cardio_cal_total**: sum of active-calorie entries from ``cardio_by_day`` whose
      date falls in ``[start, end]``; ``0.0`` when none exist.
    - **weight endpoints** via :func:`_weight_endpoints`: the reading closest to
      ``start`` (window ``[start - 7d, end]``) and the reading closest to ``end``
      (window ``[start, end + 7d]``).  If either is absent, or both share the same
      date, all weight and maintenance fields are ``None``.
    - **weight_delta_lb**: ``w_end.weight - w_start.weight``.
    - **weight_span_days**: ``max(1, (w_end.date - w_start.date).days)``.
    - **est_maintenance_per_day**: ``intake_cal_per_day - (weight_delta_lb * 3500 /
      weight_span_days)``; ``None`` when either ``intake_cal_per_day`` or
      ``weight_delta_lb`` is ``None``.

    This function is pure: it performs no DB access or I/O. All inputs must be
    pre-fetched by the caller.

    **Args:**
    - buckets (list[tuple[date, date, str]]): Sequence of ``(start, end, label)`` tuples
      defining the time windows to evaluate.
    - intake_by_day (dict[date, int]): Calories logged per day (only days that have an
      entry are present; missing dates mean no log that day).
    - cardio_by_day (dict[date, float]): Summed cardio active-calories per day; only
      days with cardio contributions are present.
    - weight_readings (list[tuple[date, float]]): Weight readings as ``(date, weight_lb)``
      pairs, in any order.

    **Returns:**
    - list[EnergyBalanceBucket]: One ``EnergyBalanceBucket`` per input bucket, in the
      same order as ``buckets``.

    **Raises:**
    - Nothing. Absent data yields ``None`` / ``0.0`` per field rather than an exception.
    """
    results: list[EnergyBalanceBucket] = []

    for start, end, label in buckets:
        # --- Intake ---
        logged_days = [d for d in intake_by_day if start <= d <= end]
        intake_cal_per_day: float | None
        if logged_days:
            intake_cal_per_day = sum(intake_by_day[d] for d in logged_days) / len(logged_days)
        else:
            intake_cal_per_day = None

        # --- Cardio ---
        cardio_cal_total = sum(
            (cardio_by_day[d] for d in cardio_by_day if start <= d <= end),
            0.0,
        )

        # --- Weight endpoints ---
        w_start, w_end = _weight_endpoints(weight_readings, start, end)

        weight_start: float | None
        weight_end: float | None
        weight_delta_lb: float | None
        weight_span_days: int | None

        if w_start is None or w_end is None or w_start[0] == w_end[0]:
            weight_start = None
            weight_end = None
            weight_delta_lb = None
            weight_span_days = None
        else:
            weight_start = w_start[1]
            weight_end = w_end[1]
            weight_delta_lb = w_end[1] - w_start[1]
            weight_span_days = max(1, (w_end[0] - w_start[0]).days)

        # --- Estimated maintenance ---
        est_maintenance_per_day: float | None
        if weight_delta_lb is None or intake_cal_per_day is None or weight_span_days is None:
            est_maintenance_per_day = None
        else:
            est_maintenance_per_day = intake_cal_per_day - (
                weight_delta_lb * 3500 / weight_span_days
            )

        results.append(
            EnergyBalanceBucket(
                bucket_start=start,
                bucket_end=end,
                label=label,
                intake_cal_per_day=intake_cal_per_day,
                cardio_cal_total=cardio_cal_total,
                weight_start=weight_start,
                weight_end=weight_end,
                weight_delta_lb=weight_delta_lb,
                weight_span_days=weight_span_days,
                est_maintenance_per_day=est_maintenance_per_day,
            )
        )

    return results
