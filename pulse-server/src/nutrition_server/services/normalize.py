from __future__ import annotations

import re

_WHITESPACE_RE = re.compile(r"\s+")


# Summary: Normalizes a food or meal name for cross-row uniqueness and lookup matching.
# Parameters:
# - name (str): User-supplied name with arbitrary casing and whitespace.
# Returns:
# - str: Lowercased, trimmed, single-spaced canonical form.
# Raises/Throws:
# - None: Pure string transform on valid string input.
def normalize_name(name: str) -> str:
    return _WHITESPACE_RE.sub(" ", name.strip().lower())
