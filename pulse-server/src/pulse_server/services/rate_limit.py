"""In-process sliding-window rate limiting.

Provides :class:`SlidingWindowRateLimiter`, a dependency-free, per-key request
limiter used to throttle abuse of expensive endpoints (e.g. the authenticated
USDA proxy) without an external store. State lives in the worker process, which
is sufficient for the single-process deployment; a multi-worker deployment that
needs a shared limit should move this to Redis.
"""

from __future__ import annotations

import time
from collections import defaultdict, deque
from threading import Lock


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
        self._lock = Lock()

    def allow(self, key: str, now: float | None = None) -> bool:
        """Record a hit for ``key`` and report whether it is within the limit.

        Expired timestamps are evicted before the decision; when the key is
        already at the limit the hit is rejected and not recorded.

        **Inputs:**
        - key (str): Identity the limit applies to (e.g. a user key).
        - now (float | None): Monotonic time override for tests; defaults to
          ``time.monotonic()``.

        **Outputs:**
        - bool: ``True`` when the request is allowed, ``False`` when the key has
          exhausted its quota for the current window.
        """
        current = time.monotonic() if now is None else now
        cutoff = current - self._window
        with self._lock:
            hits = self._hits[key]
            while hits and hits[0] <= cutoff:
                hits.popleft()
            if len(hits) >= self._max:
                return False
            hits.append(current)
            return True
