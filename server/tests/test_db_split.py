"""Unit tests for `db._split_sql_statements` and `schema.sql` structural checks.

Validates correct splitting of simple statements, preservation of
named/anonymous dollar-quoted blocks, comments, and string literals, and
skipping of empty fragments. Also asserts that the on-disk `schema.sql` —
the single source of truth — still defines every table `tables.py` knows
about, with the exact same column set, plus the alias-uniqueness triggers
(guards against accidental truncation, deletion, and hand-sync drift).
"""

import re
from pathlib import Path

import pytest

from pulse_server.db import _split_sql_statements
from pulse_server.repositories.tables import metadata

_SCHEMA_PATH = Path(__file__).resolve().parents[1] / "schema.sql"
_SCHEMA_SQL = _SCHEMA_PATH.read_text().lower()

# Keywords that can start a table-level constraint line inside a CREATE TABLE
# body — filtered out when extracting column names from the SQL text.
_CONSTRAINT_KEYWORDS = {"constraint", "unique", "check", "primary", "foreign"}


def _create_table_block(table_name: str) -> str:
    """Extract the body of a table's ``create table if not exists`` statement.

    **Inputs:**
    - table_name (str): Name of the table whose CREATE body to extract from
      the on-disk ``schema.sql``.

    **Outputs:**
    - str: The text between the statement's opening ``(`` and closing ``);``.

    **Raises:**
    - ValueError: When ``schema.sql`` has no CREATE statement for the table.
    """
    marker = f"create table if not exists {table_name} ("
    start = _SCHEMA_SQL.index(marker) + len(marker)
    return _SCHEMA_SQL[start : _SCHEMA_SQL.index("\n);", start)]


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


def test_semicolons_inside_line_comments_do_not_split() -> None:
    """A `--` comment may contain semicolons; it is absorbed into the adjacent statement."""
    sql = (
        "-- leading comment; with a semicolon\n"
        "create table a (id int);\n"
        "-- another; comment\n"
        "create table b (id int);"
    )
    assert _split_sql_statements(sql) == [
        "-- leading comment; with a semicolon\ncreate table a (id int)",
        "-- another; comment\ncreate table b (id int)",
    ]


def test_semicolons_inside_block_comments_do_not_split() -> None:
    """A `/* */` comment — including nested ones — may contain semicolons."""
    sql = "/* one; two /* nested; */ still comment; */ create table a (id int); select 1;"
    assert _split_sql_statements(sql) == [
        "/* one; two /* nested; */ still comment; */ create table a (id int)",
        "select 1",
    ]


def test_semicolons_inside_string_literals_do_not_split() -> None:
    """Single-quoted literals may contain semicolons and `''` escapes."""
    sql = "insert into a (x) values ('a;b'); insert into a (x) values ('it''s; ok');"
    assert _split_sql_statements(sql) == [
        "insert into a (x) values ('a;b')",
        "insert into a (x) values ('it''s; ok')",
    ]


def test_schema_sql_defines_sessions_indexes() -> None:
    """`schema.sql` still defines the sessions indexes the auth layer expects."""
    assert "create index if not exists idx_sessions_email" in _SCHEMA_SQL
    assert "create index if not exists idx_sessions_expires_at" in _SCHEMA_SQL


@pytest.mark.parametrize("table_name", sorted(metadata.tables))
def test_schema_sql_defines_table(table_name: str) -> None:
    """Every table `tables.py` declares survives in `schema.sql` (truncation guard)."""
    assert f"create table if not exists {table_name} (" in _SCHEMA_SQL


@pytest.mark.parametrize("table_name", sorted(metadata.tables))
def test_schema_sql_columns_match_tables_py(table_name: str) -> None:
    """Each table's column set is identical in `schema.sql` and `tables.py` (drift guard)."""
    block = _create_table_block(table_name)
    declared = {
        match.group(1) for match in re.finditer(r"^ {2}(\w+)", block, re.MULTILINE)
    } - _CONSTRAINT_KEYWORDS
    expected = {column.name for column in metadata.tables[table_name].columns}
    assert declared == expected


def test_schema_sql_defines_alias_triggers() -> None:
    """Both alias-uniqueness functions and their triggers survive in `schema.sql`."""
    assert "create or replace function check_food_memory_alias_uniqueness()" in _SCHEMA_SQL
    assert "create or replace function check_meals_alias_uniqueness()" in _SCHEMA_SQL
    assert "create trigger food_memory_alias_uniqueness" in _SCHEMA_SQL
    assert "create trigger meals_alias_uniqueness" in _SCHEMA_SQL
