"""Wire-contract drift guard: the app's OpenAPI schema must match the committed snapshot.

The server and iOS client share a JSON-over-HTTP wire format mirrored by hand
(Pydantic DTOs ↔ Codable structs); nothing else fails when one side drifts.
This test pins the server's public surface to ``server/openapi.snapshot.json``
so any route/DTO change produces a reviewable diff — the moment the CLAUDE.md
"update the other side" instruction must fire.

On an intentional change, regenerate with:

    uv run python -m pulse_server.scripts.dump_openapi
"""

from __future__ import annotations

import json
from pathlib import Path

from pulse_server.scripts.dump_openapi import openapi_snapshot_json

SNAPSHOT_PATH = Path(__file__).resolve().parents[1] / "openapi.snapshot.json"
REGEN_HINT = (
    "regenerate with `uv run python -m pulse_server.scripts.dump_openapi` "
    "and, if routes/DTOs changed, update the iOS mirrors in ios/Pulse/Models/"
)


def test_openapi_matches_committed_snapshot():
    """The live OpenAPI schema equals the committed snapshot byte-for-byte."""
    assert SNAPSHOT_PATH.exists(), f"missing {SNAPSHOT_PATH.name}: {REGEN_HINT}"
    committed = SNAPSHOT_PATH.read_text()
    current = openapi_snapshot_json()
    # Parsed-dict comparison first for a structured pytest diff on mismatch...
    assert json.loads(current) == json.loads(committed), f"OpenAPI surface changed: {REGEN_HINT}"
    # ...then exact text so formatting drift can't hide a stale snapshot.
    assert current == committed, f"snapshot formatting is stale: {REGEN_HINT}"


def test_snapshot_covers_core_wire_surface():
    """Sanity: the snapshot actually contains the routes the iOS client depends on."""
    paths = json.loads(openapi_snapshot_json())["paths"]
    for expected in ("/entries", "/summary/{summary_date}", "/weight", "/activity/workouts"):
        assert expected in paths, f"expected core route {expected} in OpenAPI paths"
