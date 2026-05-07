from diet_tracker_server.services.normalize import normalize_name


def test_normalize_lowercases_and_trims() -> None:
    assert normalize_name("  Chicken Breast  ") == "chicken breast"


def test_normalize_collapses_whitespace() -> None:
    assert normalize_name("Chicken\t  Breast\nGrilled") == "chicken breast grilled"


def test_normalize_idempotent() -> None:
    once = normalize_name("My Wrap")
    assert normalize_name(once) == once
