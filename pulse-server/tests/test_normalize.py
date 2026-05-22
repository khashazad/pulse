"""Unit tests for `services.normalize.normalize_name`.

Verifies lowercase + trim, collapse of mixed whitespace (tabs, newlines,
multiple spaces) to single spaces, and idempotence on already-normalized
input.
"""

from pulse_server.services.normalize import normalize_name


def test_normalize_lowercases_and_trims() -> None:
    """`normalize_name` lowercases and strips leading/trailing whitespace."""
    assert normalize_name("  Chicken Breast  ") == "chicken breast"


def test_normalize_collapses_whitespace() -> None:
    """Mixed whitespace runs collapse to single spaces."""
    assert normalize_name("Chicken\t  Breast\nGrilled") == "chicken breast grilled"


def test_normalize_idempotent() -> None:
    """Applying `normalize_name` twice yields the same result as applying once."""
    once = normalize_name("My Wrap")
    assert normalize_name(once) == once
