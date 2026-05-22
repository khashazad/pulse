"""Name-normalization helpers for food/meal lookup.

Provides :func:`normalize_name`, which canonicalizes user-supplied food and
meal names so the same phrase under different casing or whitespace maps to a
single row. Used by every service that reads or writes ``normalized_name``
columns on ``food_memory``, ``custom_foods``, or ``meals``.
"""

from __future__ import annotations

import re

_WHITESPACE_RE = re.compile(r"\s+")


def normalize_name(name: str) -> str:
    """Canonicalize a food or meal name for cross-row uniqueness and lookup matching.

    Lowercases, strips outer whitespace, and collapses internal whitespace
    runs to single spaces.

    **Inputs:**
    - name (str): User-supplied name with arbitrary casing and whitespace.

    **Outputs:**
    - str: Lowercased, trimmed, single-spaced canonical form.
    """
    return _WHITESPACE_RE.sub(" ", name.strip().lower())
