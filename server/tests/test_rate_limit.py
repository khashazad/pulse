"""Unit tests for `pulse_server.services.rate_limit.SlidingWindowRateLimiter`.

Covers per-key isolation, rejection at the limit, and recovery once the window
slides, using injected monotonic timestamps for determinism.
"""

from __future__ import annotations

from pulse_server.services.rate_limit import SlidingWindowRateLimiter


def test_allows_up_to_limit_then_rejects() -> None:
    """The first `max_requests` hits pass; the next is rejected within the window."""
    limiter = SlidingWindowRateLimiter(max_requests=3, window_seconds=60.0)
    assert limiter.allow("user", now=0.0) is True
    assert limiter.allow("user", now=1.0) is True
    assert limiter.allow("user", now=2.0) is True
    assert limiter.allow("user", now=3.0) is False


def test_window_slides_to_allow_again() -> None:
    """Once the oldest hit ages out of the window, a new hit is allowed."""
    limiter = SlidingWindowRateLimiter(max_requests=2, window_seconds=10.0)
    assert limiter.allow("user", now=0.0) is True
    assert limiter.allow("user", now=5.0) is True
    assert limiter.allow("user", now=9.0) is False
    # At t=11 the t=0 hit (<= 11-10) has expired, freeing a slot.
    assert limiter.allow("user", now=11.0) is True


def test_keys_are_isolated() -> None:
    """Each key has an independent budget."""
    limiter = SlidingWindowRateLimiter(max_requests=1, window_seconds=60.0)
    assert limiter.allow("a", now=0.0) is True
    assert limiter.allow("a", now=1.0) is False
    assert limiter.allow("b", now=1.0) is True


def test_idle_keys_are_pruned() -> None:
    """Keys whose every hit has aged out are dropped from the internal dict."""
    limiter = SlidingWindowRateLimiter(max_requests=2, window_seconds=10.0)
    assert limiter.allow("old", now=0.0) is True
    # 100s later "old" is fully expired; touching another key prunes it.
    assert limiter.allow("fresh", now=100.0) is True
    assert "old" not in limiter._hits
    assert "fresh" in limiter._hits


def test_reset_clears_all_budgets() -> None:
    """`reset()` restores the full budget for every key."""
    limiter = SlidingWindowRateLimiter(max_requests=1, window_seconds=60.0)
    assert limiter.allow("a", now=0.0) is True
    assert limiter.allow("a", now=1.0) is False
    limiter.reset()
    assert limiter.allow("a", now=2.0) is True
