"""Add aliases columns to food_memory and meals.

Revision ID: 20260511_000001
Revises: 20260510_000001
Create Date: 2026-05-11T00:00:00Z
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "20260511_000001"
down_revision = "20260510_000001"
branch_labels = None
depends_on = None


_TRIGGER_FN_TMPL = """
create or replace function {fn_name}() returns trigger
language plpgsql as $$
declare
  collision_name text;
begin
  if NEW.aliases is not null and array_length(NEW.aliases, 1) is not null then
    select normalized_name into collision_name from {table}
    where user_key = NEW.user_key
      and id is distinct from NEW.id
      and normalized_name = ANY(NEW.aliases)
    limit 1;
    if collision_name is not null then
      raise exception 'alias collides with canonical name %', collision_name
        using errcode = '23505';
    end if;

    select normalized_name into collision_name from {table}
    where user_key = NEW.user_key
      and id is distinct from NEW.id
      and aliases && NEW.aliases
    limit 1;
    if collision_name is not null then
      raise exception 'alias collides with alias of %', collision_name
        using errcode = '23505';
    end if;
  end if;

  select normalized_name into collision_name from {table}
  where user_key = NEW.user_key
    and id is distinct from NEW.id
    and NEW.normalized_name = ANY(aliases)
  limit 1;
  if collision_name is not null then
    raise exception 'name collides with alias of %', collision_name
      using errcode = '23505';
  end if;

  return NEW;
end;
$$;
"""


def upgrade() -> None:
    op.add_column(
        "food_memory",
        sa.Column(
            "aliases",
            postgresql.ARRAY(sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::text[]"),
        ),
    )
    op.add_column(
        "meals",
        sa.Column(
            "aliases",
            postgresql.ARRAY(sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::text[]"),
        ),
    )

    op.create_index(
        "idx_food_memory_aliases",
        "food_memory",
        ["aliases"],
        unique=False,
        postgresql_using="gin",
    )
    op.create_index(
        "idx_meals_aliases",
        "meals",
        ["aliases"],
        unique=False,
        postgresql_using="gin",
    )

    op.create_check_constraint(
        "food_memory_alias_not_self",
        "food_memory",
        "not (normalized_name = ANY(aliases))",
    )
    op.create_check_constraint(
        "meals_alias_not_self",
        "meals",
        "not (normalized_name = ANY(aliases))",
    )

    op.execute(
        _TRIGGER_FN_TMPL.format(
            fn_name="check_food_memory_alias_uniqueness",
            table="food_memory",
        )
    )
    op.execute(
        _TRIGGER_FN_TMPL.format(
            fn_name="check_meals_alias_uniqueness",
            table="meals",
        )
    )

    op.execute(
        "create trigger food_memory_alias_uniqueness "
        "before insert or update on food_memory "
        "for each row execute function check_food_memory_alias_uniqueness();"
    )
    op.execute(
        "create trigger meals_alias_uniqueness "
        "before insert or update on meals "
        "for each row execute function check_meals_alias_uniqueness();"
    )


def downgrade() -> None:
    op.execute("drop trigger if exists meals_alias_uniqueness on meals;")
    op.execute("drop trigger if exists food_memory_alias_uniqueness on food_memory;")
    op.execute("drop function if exists check_meals_alias_uniqueness();")
    op.execute("drop function if exists check_food_memory_alias_uniqueness();")
    op.drop_constraint("meals_alias_not_self", "meals", type_="check")
    op.drop_constraint("food_memory_alias_not_self", "food_memory", type_="check")
    op.drop_index("idx_meals_aliases", table_name="meals")
    op.drop_index("idx_food_memory_aliases", table_name="food_memory")
    op.drop_column("meals", "aliases")
    op.drop_column("food_memory", "aliases")
