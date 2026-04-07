from __future__ import annotations


# Summary: Escapes LIKE/ILIKE wildcard characters in user-provided search terms.
# Parameters:
# - query (str): Raw user query string used for phrase lookup.
# Returns:
# - str: Escaped string safe for use inside a LIKE pattern with backslash escape semantics.
# Raises/Throws:
# - None: String replacement is deterministic and non-throwing.
def escape_like_query(query: str) -> str:
    return query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
