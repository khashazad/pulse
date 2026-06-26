"""Pure trend math for activity summaries: est-1RM, period bounds, by-type
rollup, PR-aware top lifts, and volume bucketing. No DB access."""

from __future__ import annotations

import calendar
from datetime import date as DateValue
from datetime import timedelta as TimeDeltaValue

from pulse_server.models.activity import (
    ActivityPeriod,
    GroupBreakdown,
    TopLift,
    TypeBreakdown,
    VolumeBucket,
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


def rollup_by_type(rows: list[dict], top_n: int = 5) -> list[TypeBreakdown]:
    """Aggregate duration by ``activity_type``, keep top N, bucket the rest as Other.

    **Inputs:**
    - rows (list[dict]): Rows with ``activity_type`` and ``duration_min`` keys.
    - top_n (int): Number of named types to keep before bucketing.

    **Outputs:**
    - list[TypeBreakdown]: Sorted desc by duration, each with its share (0..1) of
      total duration; a trailing ``Other`` slice when more than ``top_n`` types.
    """
    agg: dict[str, dict[str, float]] = {}
    for r in rows:
        a = agg.setdefault(r["activity_type"], {"duration": 0.0, "count": 0.0})
        a["duration"] += float(r["duration_min"] or 0)
        a["count"] += 1
    total = sum(a["duration"] for a in agg.values()) or 1.0
    ordered = sorted(agg.items(), key=lambda kv: kv[1]["duration"], reverse=True)
    out: list[TypeBreakdown] = []
    for name, a in ordered[:top_n]:
        out.append(
            TypeBreakdown(
                activity_type=name,
                count=int(a["count"]),
                duration_min=a["duration"],
                share=a["duration"] / total,
            )
        )
    rest = ordered[top_n:]
    if rest:
        dur = sum(a["duration"] for _, a in rest)
        count = sum(a["count"] for _, a in rest)
        out.append(
            TypeBreakdown(
                activity_type="Other", count=int(count), duration_min=dur, share=dur / total
            )
        )
    return out


def rollup_by_group(
    rows: list[dict], weights_types: set[str] | frozenset[str]
) -> list[GroupBreakdown]:
    """Aggregate duration by activity_type, bucket each into weights/cardio, and
    nest the per-type detail under its group.

    **Inputs:**
    - rows (list[dict]): Rows with ``activity_type`` and ``duration_min`` keys.
    - weights_types (set[str]): The activity types that belong to the Weights group.

    **Outputs:**
    - list[GroupBreakdown]: Non-empty groups, desc by duration. Each group's
      ``share`` is its fraction of total duration; each subtype's ``share`` is its
      fraction of the group's duration; subtypes are desc by duration.
    """
    agg: dict[str, dict[str, float]] = {}
    for r in rows:
        a = agg.setdefault(r["activity_type"], {"duration": 0.0, "count": 0.0})
        a["duration"] += float(r["duration_min"] or 0)
        a["count"] += 1
    total = sum(a["duration"] for a in agg.values()) or 1.0
    groups: dict[str, list[tuple[str, dict[str, float]]]] = {"weights": [], "cardio": []}
    for name, a in agg.items():
        groups["weights" if name in weights_types else "cardio"].append((name, a))
    out: list[GroupBreakdown] = []
    for gname, members in groups.items():
        if not members:
            continue
        gdur = sum(a["duration"] for _, a in members) or 1.0
        gcount = sum(a["count"] for _, a in members)
        subtypes = [
            TypeBreakdown(
                activity_type=name,
                count=int(a["count"]),
                duration_min=a["duration"],
                share=a["duration"] / gdur,
            )
            for name, a in sorted(members, key=lambda kv: kv[1]["duration"], reverse=True)
        ]
        out.append(
            GroupBreakdown(
                group=gname,
                count=int(gcount),
                duration_min=sum(a["duration"] for _, a in members),
                share=sum(a["duration"] for _, a in members) / total,
                subtypes=subtypes,
            )
        )
    out.sort(key=lambda g: g.duration_min, reverse=True)
    return out


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
