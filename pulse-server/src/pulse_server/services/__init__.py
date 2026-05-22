"""Service-layer package for the pulse server.

Exposes the public business-logic entry points used by routers: daily-summary
construction, food-entry creation with side effects, deterministic daily-log
UUID derivation, and food/meal name normalization. Modules in this package own
business rules and transaction boundaries; they sit between routers (HTTP) and
repositories (SQL), and may compose multiple repositories to fulfill a single
use case.
"""

__all__ = [
    "build_daily_summary",
    "create_entries_with_side_effects",
    "daily_log_id",
    "normalize_name",
]
