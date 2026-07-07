"""Regenerate the committed OpenAPI wire-contract snapshot.

Serializes the FastAPI app's OpenAPI schema (deterministically: sorted keys,
2-space indent, trailing newline) to ``server/openapi.snapshot.json``, which
``tests/test_openapi_snapshot.py`` pins the public HTTP surface against.
Run after any intentional route/DTO change:

    uv run python -m pulse_server.scripts.dump_openapi

The schema covers the FastAPI routes only — the MCP mount at ``/mcp`` and the
FastMCP-emitted OAuth metadata routes are separate ASGI apps outside it.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

SNAPSHOT_PATH = Path(__file__).resolve().parents[3] / "openapi.snapshot.json"


def openapi_snapshot_json() -> str:
    """Serialize the app's OpenAPI schema in the canonical snapshot form.

    Imports ``pulse_server.app`` lazily so callers control the environment
    first (tests seed env in ``conftest.py``; :func:`main` seeds dummies).

    **Outputs:**
    - str: ``json.dumps(app.openapi(), sort_keys=True, indent=2)`` plus a
      trailing newline — the exact bytes stored in ``openapi.snapshot.json``.

    **Raises:**
    - pydantic_core.ValidationError: When required settings (``DATABASE_URL``,
      ``USDA_API_KEY``) are absent from the environment and ``.env``.
    """
    from pulse_server.app import app

    return json.dumps(app.openapi(), sort_keys=True, indent=2) + "\n"


def main() -> None:
    """Write the snapshot file, seeding dummy required env so it runs anywhere.

    The OpenAPI schema does not depend on the DB or USDA credentials, so
    placeholder values are sufficient when no ``.env`` is present.

    **Outputs:**
    - None: Writes ``openapi.snapshot.json`` and prints the path.
    """
    os.environ.setdefault("DATABASE_URL", "postgresql://localhost/snapshot")
    os.environ.setdefault("USDA_API_KEY", "snapshot")
    os.environ.setdefault("APP_ENV", "local")
    SNAPSHOT_PATH.write_text(openapi_snapshot_json())
    print(f"wrote {SNAPSHOT_PATH}")


if __name__ == "__main__":
    main()
