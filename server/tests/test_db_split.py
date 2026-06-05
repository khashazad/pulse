"""Unit tests for `db._split_sql_statements` and a `schema.sql` smoke check.

Validates correct splitting of simple statements, preservation of
named/anonymous dollar-quoted blocks, and skipping of empty fragments.
Also asserts that the on-disk `schema.sql` still defines the `sessions`
table and its indexes.
"""

from pulse_server.db import _split_sql_statements


def test_splits_simple_statements() -> None:
    """Two semicolon-separated CREATE TABLEs split into two trimmed statements."""
    sql = "create table a (id int); create table b (id int);"
    assert _split_sql_statements(sql) == [
        "create table a (id int)",
        "create table b (id int)",
    ]


def test_preserves_dollar_quoted_blocks() -> None:
    """Named `$body$` blocks are kept intact, including internal semicolons."""
    sql = """
    create table a (id int);
    do $body$
    begin
      if true then
        alter table a add column x int;
      end if;
    end
    $body$;
    create index idx on a(id);
    """
    statements = _split_sql_statements(sql)
    assert len(statements) == 3
    assert statements[0] == "create table a (id int)"
    assert "alter table a add column x int;" in statements[1]
    assert statements[1].startswith("do $body$")
    assert statements[1].endswith("$body$")
    assert statements[2] == "create index idx on a(id)"


def test_handles_unnamed_dollar_quotes() -> None:
    """Anonymous `$$ ... $$` blocks are also preserved as a single statement."""
    sql = "do $$ begin perform 1; end $$;"
    statements = _split_sql_statements(sql)
    assert len(statements) == 1
    assert "perform 1;" in statements[0]


def test_skips_empty_statements() -> None:
    """Consecutive semicolons produce no empty statements in the output."""
    assert _split_sql_statements(";;select 1;;") == ["select 1"]


def test_schema_sql_contains_sessions_table():
    """`schema.sql` still defines the `sessions` table and its expected indexes."""
    from pathlib import Path

    sql = Path("schema.sql").read_text()
    lower = sql.lower()
    assert "create table if not exists sessions" in lower
    assert "token_hash" in lower
    assert "expires_at" in lower
    assert "create index if not exists idx_sessions_email" in lower
    assert "create index if not exists idx_sessions_expires_at" in lower
