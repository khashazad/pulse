from diet_tracker_server.db import _split_sql_statements


def test_splits_simple_statements() -> None:
    sql = "create table a (id int); create table b (id int);"
    assert _split_sql_statements(sql) == [
        "create table a (id int)",
        "create table b (id int)",
    ]


def test_preserves_dollar_quoted_blocks() -> None:
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
    sql = "do $$ begin perform 1; end $$;"
    statements = _split_sql_statements(sql)
    assert len(statements) == 1
    assert "perform 1;" in statements[0]


def test_skips_empty_statements() -> None:
    assert _split_sql_statements(";;select 1;;") == ["select 1"]
