"""Repository package: SQLAlchemy-Core data-access layer for the pulse.

Re-exports the public repository classes used throughout the codebase so callers
can import them from a single namespace. Each repository owns the SQL for a
single table (or a tightly-coupled group of tables) and returns plain ``dict``
rows so services and routers stay decoupled from SQLAlchemy result objects.

This module sits at the bottom of the request flow (router → service →
repository) and is the only layer permitted to issue SQL statements against the
Postgres schema defined in ``repositories/tables.py``.
"""

from pulse_server.repositories.custom_foods import CustomFoodsRepository
from pulse_server.repositories.entries import EntriesRepository
from pulse_server.repositories.food_memory import FoodMemoryRepository
from pulse_server.repositories.logs import LogsRepository
from pulse_server.repositories.meals import MealsRepository
from pulse_server.repositories.targets import TargetsRepository

__all__ = [
    "CustomFoodsRepository",
    "EntriesRepository",
    "FoodMemoryRepository",
    "LogsRepository",
    "MealsRepository",
    "TargetsRepository",
]
