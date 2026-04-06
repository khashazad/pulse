from __future__ import annotations

import uuid
from datetime import date as DateValue


# Summary: Derives a stable UUID for a user's daily log date.
# Parameters:
# - user_key (str): Unique user identifier owning the nutrition log.
# - log_date (DateValue): Target log date used for deterministic UUID derivation.
# Returns:
# - str: UUID5 string derived from user key and date.
# Raises/Throws:
# - None: UUID derivation is deterministic and non-throwing for valid inputs.
def daily_log_id(user_key: str, log_date: DateValue) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{user_key}:{log_date.isoformat()}"))
