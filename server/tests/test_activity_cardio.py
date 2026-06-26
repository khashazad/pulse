"""Unit tests for the cardio default heuristic."""

from __future__ import annotations

from pulse_server.services.activity_cardio import DEFAULT_CARDIO_TYPES, effective_is_cardio


def test_override_false_overrides_default_cardio() -> None:
    """A type in DEFAULT_CARDIO_TYPES with an explicit False override returns False."""
    assert effective_is_cardio("Running", {"Running": False}) is False


def test_non_default_no_override_returns_false() -> None:
    """A type not in DEFAULT_CARDIO_TYPES with no override returns False."""
    assert effective_is_cardio("TraditionalStrengthTraining", {}) is False


def test_default_cardio_no_override_returns_true() -> None:
    """A type in DEFAULT_CARDIO_TYPES with no override returns True."""
    assert effective_is_cardio("Running", {}) is True


def test_override_true_on_non_default_returns_true() -> None:
    """An explicit True override on a non-default type returns True."""
    assert (
        effective_is_cardio("TraditionalStrengthTraining", {"TraditionalStrengthTraining": True})
        is True
    )


def test_all_default_cardio_types_recognised() -> None:
    """Every type in DEFAULT_CARDIO_TYPES resolves to True with no overrides."""
    for activity_type in DEFAULT_CARDIO_TYPES:
        assert effective_is_cardio(activity_type, {}) is True, f"{activity_type!r} should be cardio"
