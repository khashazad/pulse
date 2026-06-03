"""Deterministic daily-log UUID derivation (layer-neutral).

Provides :func:`daily_log_id`, which maps ``(user_key, log_date)`` to a stable
UUID5 used as the primary key for ``daily_logs`` rows. The deterministic
mapping lets callers upsert idempotently per day without first reading the
row's id from the database.

Lives at the package root (not under ``services/``) so both the repositories
layer and the services layer can import it without the repositories layer
depending on a service — avoiding an inverted layer dependency.
"""

from __future__ import annotations

import uuid
from datetime import date as DateValue


def daily_log_id(user_key: str, log_date: DateValue) -> str:
    """Derive a stable UUID for a user's daily log on a given date.

    Uses UUID5 over ``f"{user_key}:{log_date.isoformat()}"`` in the URL
    namespace, so the same inputs always produce the same UUID — letting
    callers upsert daily logs without an extra read.

    **Inputs:**
    - user_key (str): Unique user identifier owning the diet log.
    - log_date (DateValue): Target log date used for deterministic UUID
      derivation.

    **Outputs:**
    - str: UUID5 string derived from user key and date.
    """
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{user_key}:{log_date.isoformat()}"))
