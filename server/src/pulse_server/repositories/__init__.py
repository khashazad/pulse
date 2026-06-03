"""Repository package: SQLAlchemy-Core data-access layer for Pulse.

Each repository owns the SQL for a single table (or a tightly-coupled group of
tables) and returns plain ``dict`` rows so services and routers stay decoupled
from SQLAlchemy result objects.

This package sits at the bottom of the request flow (router → service →
repository) and is the only layer permitted to issue SQL statements against the
Postgres schema defined in ``repositories/tables.py``.

Repositories are imported directly from their submodules
(``from pulse_server.repositories.meals import MealsRepository``); this package
intentionally re-exports nothing, so there is one consistent import style across
the codebase.
"""
