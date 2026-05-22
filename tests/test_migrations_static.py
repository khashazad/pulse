"""Static regression checks for hand-written Alembic migrations."""

from __future__ import annotations

from pathlib import Path


def test_progress_photo_tags_migration_guards_legacy_slot_reads() -> None:
    """The progress-photo tag migration only reads `slot` inside an existence guard."""
    source = Path("alembic/versions/20260518_000001_progress_photo_tags.py").read_text()
    lowered = source.lower()
    guard_index = lowered.index("column_name = 'slot'")
    assert lowered.index("where slot is not null") > guard_index
    assert lowered.index("pp.slot = t.normalized_name") > guard_index
    assert lowered.index("drop column if exists slot") > guard_index
