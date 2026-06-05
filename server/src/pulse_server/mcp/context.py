"""Per-build context and shared helpers for the MCP tool modules.

:class:`ToolContext` bundles the immutable values every tool closure needs —
the single-tenant ``user_key``, the server timezone, and the lazy
``usda_getter`` — so each ``tools/*.py`` module can close over one object
instead of a grab-bag of outer locals. The helper functions (:func:`basis_for`,
:func:`parse_consumed_at`, :func:`target_and_remaining`) are the small,
tool-agnostic utilities the food/meal/summary tools share.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from typing import Any
from zoneinfo import ZoneInfo

from fastmcp.exceptions import ToolError

from pulse_server.macro_aggregates import remaining_macros
from pulse_server.models import MacroTargets, MacroTotals
from pulse_server.models.adapters import macro_targets_from_row


@dataclass(frozen=True)
class ToolContext:
    """Immutable context shared by every registered MCP tool.

    **Inputs:**
    - user_key (str): Single-tenant data scope mirrored from the REST surface.
    - tz (ZoneInfo): Server timezone used to stamp/parse ``consumed_at`` and
      derive day buckets.
    - usda_getter (Callable[[], Any]): Zero-arg callable returning the live
      ``USDAClient``; consulted lazily inside ``search_food`` so the server can
      be built before lifespan startup without import cycles.
    """

    user_key: str
    tz: ZoneInfo
    usda_getter: Callable[[], Any]


def basis_for(food: dict[str, Any]) -> str:
    """Infer the macro basis label for a USDA search row.

    **Inputs:**
    - food (dict[str, Any]): Normalized USDA food row.

    **Outputs:**
    - str: ``"per_serving"`` when the row carries a ``serving_size``,
      otherwise ``"per_100g"``.
    """
    return "per_serving" if food.get("serving_size") else "per_100g"


def parse_consumed_at(value: str | None, tz: ZoneInfo) -> DateTimeValue | None:
    """Parse the MCP ``consumed_at`` argument shared by ``log_food`` / ``log_meal``.

    Accepts either ``YYYY-MM-DD`` (expanded to noon in ``tz``) or any ISO-8601
    timestamp (naive strings are stamped with ``tz``). Returns ``None`` when
    ``value`` is ``None`` so callers can fall back to request-scoped ``now``.

    **Inputs:**
    - value (str | None): Raw user input.
    - tz (ZoneInfo): Server timezone used to localize date-only and naive
      timestamps.

    **Outputs:**
    - datetime | None: Timezone-aware datetime, or ``None`` when no value was
      provided.

    **Exceptions:**
    - ToolError: Raised when ``value`` is non-empty but does not parse as
      either ``YYYY-MM-DD`` or ISO-8601.
    """
    if value is None:
        return None
    try:
        return DateTimeValue.combine(
            DateValue.fromisoformat(value),
            DateTimeValue.min.time().replace(hour=12),
            tzinfo=tz,
        )
    except ValueError:
        pass
    try:
        parsed = DateTimeValue.fromisoformat(value)
    except ValueError as exc:
        raise ToolError(f"Invalid consumed_at '{value}', expected YYYY-MM-DD or ISO-8601") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=tz)
    return parsed


def target_and_remaining(
    target_row: dict[str, Any] | None,
    daily_totals: MacroTotals,
) -> tuple[MacroTargets | None, MacroTotals | None]:
    """Compute the target profile and remaining-vs-target totals for a day.

    **Inputs:**
    - target_row (dict[str, Any] | None): Row from ``TargetsRepository`` or
      ``None`` when no target profile exists.
    - daily_totals (MacroTotals): Consumed macros for the day.

    **Outputs:**
    - tuple[MacroTargets | None, MacroTotals | None]: ``(target, remaining)``
      where both are ``None`` when no profile exists, and ``remaining`` is the
      element-wise difference rounded to one decimal place for macro grams.
    """
    if target_row is None:
        return None, None
    target_obj = macro_targets_from_row(target_row)
    return target_obj, remaining_macros(target_obj, daily_totals)
