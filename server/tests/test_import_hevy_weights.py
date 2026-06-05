"""Unit tests for the Hevy weight import utility."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest


def _load_run():
    """Load the script module from its filesystem path and return `_run`.

    **Outputs:**
    - Callable: The script's async `_run` function.

    **Exceptions:**
    - AssertionError: Raised when the import spec cannot be created.
    """
    path = Path("scripts/import_hevy_weights.py")
    spec = importlib.util.spec_from_file_location("import_hevy_weights", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module._run


@pytest.mark.asyncio
async def test_empty_csv_dry_run_does_not_crash(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A header-only Hevy CSV exits cleanly in dry-run mode."""
    csv_path = tmp_path / "empty.csv"
    csv_path.write_text("date,weight_lbs,fat_percent\n")

    await _load_run()(csv_path, user_key="khash", dry_run=True)

    assert "parsed 0 rows" in capsys.readouterr().out
