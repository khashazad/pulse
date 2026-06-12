"""In-process sliding-window rate limiting.

Provides :class:`SlidingWindowRateLimiter`, a dependency-free, per-key request
limiter used to throttle abuse of expensive endpoints (the authenticated USDA
proxy and the unauthenticated ``/auth/google/*`` bootstrap routes) without an
external store. State lives in the worker process, which is sufficient for the
single-process deployment; a multi-worker deployment that needs a shared limit
should move this to Redis.

No lock is held: the app runs on a single-threaded asyncio event loop and
``allow`` contains no ``await`` points, so its read-modify-write on ``_hits``
is never interleaved. (The previous ``threading.Lock`` was a blocking OS mutex
on an async path — wrong primitive, and unnecessary here.)
"""

from __future__ import annotations

import time
from collections import defaultdict, deque


class SlidingWindowRateLimiter:
    """Allow at most ``max_requests`` per ``window_seconds`` for each key.

    The window slides continuously: each key keeps the timestamps of its recent
    hits and drops any older than the window before deciding. Intended for
    coarse per-user/session throttling, not precise distributed quotas.
    """

    def __init__(self, max_requests: int, window_seconds: float) -> None:
        """Configure the limit and bind the per-key hit log.

        **Inputs:**
        - max_requests (int): Maximum allowed hits within any window.
        - window_seconds (float): Length of the sliding window in seconds.
        """
        self._max = max_requests
        self._window = window_seconds
        self._hits: dict[str, deque[float]] = defaultdict(deque)

    def allow(self, key: str, now: float | None = None) -> bool:
        """Record a hit for ``key`` and report whether it is within the limit.

        Expired timestamps are evicted before the decision; when the key is
        already at the limit the hit is rejected and not recorded. Keys whose
        hits have all expired are dropped entirely so the dict does not grow
        without bound across many distinct keys (per-IP keying, future
        multi-user keying).

        **Inputs:**
        - key (str): Identity the limit applies to (e.g. a user key or client IP).
        - now (float | None): Monotonic time override for tests; defaults to
          ``time.monotonic()``.

        **Outputs:**
        - bool: ``True`` when the request is allowed, ``False`` when the key has
          exhausted its quota for the current window.
        """
        current = time.monotonic() if now is None else now
        cutoff = current - self._window
        hits = self._hits[key]
        while hits and hits[0] <= cutoff:
            hits.popleft()
        if len(hits) >= self._max:
            return False
        hits.append(current)
        self._prune_idle(cutoff, keep=key)
        return True

    def reset(self) -> None:
        """Clear all recorded hits for every key.

        Intended for tests that exercise rate-limited endpoints repeatedly and
        need a deterministic starting budget.

        **Outputs:**
        - None: Returns nothing.
        """
        self._hits.clear()

    def _prune_idle(self, cutoff: float, *, keep: str) -> None:
        """Drop keys whose every recorded hit is older than ``cutoff``.

        **Inputs:**
        - cutoff (float): Monotonic timestamp; hits at or before it are expired.
        - keep (str): Key to retain even when empty (the one just touched).

        **Outputs:**
        - None: Returns nothing.
        """
        idle = [k for k, dq in self._hits.items() if k != keep and (not dq or dq[-1] <= cutoff)]
        for k in idle:
            del self._hits[k]
