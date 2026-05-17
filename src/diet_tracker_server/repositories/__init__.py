"""Repository package: SQLAlchemy-Core data-access layer for the diet tracker.

Re-exports the public repository classes used throughout the codebase so callers
can import them from a single namespace. Each repository owns the SQL for a
single table (or a tightly-coupled group of tables) and returns plain ``dict``
rows so services and routers stay decoupled from SQLAlchemy result objects.

This module sits at the bottom of the request flow (router → service →
repository) and is the only layer permitted to issue SQL statements against the
Postgres schema defined in ``repositories/tables.py``.
"""

from diet_tracker_server.repositories.custom_foods import CustomFoodsRepository
from diet_tracker_server.repositories.entries import EntriesRepository
from diet_tracker_server.repositories.food_memory import FoodMemoryRepository
from diet_tracker_server.repositories.logs import LogsRepository
from diet_tracker_server.repositories.meals import MealsRepository
from diet_tracker_server.repositories.targets import TargetsRepository

__all__ = [
    "CustomFoodsRepository",
    "EntriesRepository",
    "FoodMemoryRepository",
    "LogsRepository",
    "MealsRepository",
    "TargetsRepository",
]
