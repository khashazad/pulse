"""Add weight_entries and target_weight_lb column.

Revision ID: 20260513_000001
Revises: 20260511_000001
Create Date: 2026-05-13T00:00:00Z
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260513_000001"
down_revision = "20260511_000001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        create table if not exists weight_entries (
          id uuid primary key default gen_random_uuid(),
          user_key text not null,
          log_date date not null,
          weight_lb numeric(6,2) not null check (weight_lb > 0),
          source_unit text not null check (source_unit in ('lb','kg')),
          created_at timestamptz not null default now(),
          updated_at timestamptz not null default now(),
          unique (user_key, log_date)
        )
        """
    )
    op.execute(
        "create index if not exists idx_weight_entries_user_key_log_date "
        "on weight_entries(user_key, log_date)"
    )
    op.execute(
        "alter table daily_target_profile "
        "add column if not exists target_weight_lb numeric(6,2)"
    )


def downgrade() -> None:
    op.execute("alter table daily_target_profile drop column if exists target_weight_lb")
    op.execute("drop index if exists idx_weight_entries_user_key_log_date")
    op.execute("drop table if exists weight_entries")
