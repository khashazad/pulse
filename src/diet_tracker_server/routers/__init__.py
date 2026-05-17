"""FastAPI router package for the diet tracker server.

Each module in this package exposes an ``APIRouter`` covering one slice of the
HTTP surface (auth, weight, entries, meals, custom foods, food memory,
containers, progress photos, daily logs, summaries, targets, and USDA search).
The package itself is intentionally empty — modules are imported and mounted by
``diet_tracker_server.app`` so the import graph stays one-directional.
"""
