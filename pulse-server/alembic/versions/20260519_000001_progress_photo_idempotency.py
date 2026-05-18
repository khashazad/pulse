"""Add idempotency_key column for idempotent progress-photo uploads.

Revision ID: 20260519_000001
Revises: 20260518_000001
Create Date: 2026-05-19T00:00:00Z
"""

from __future__ import annotations

from alembic import op


revision = "20260519_000001"
down_revision = "20260518_000001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "alter table progress_photos add column if not exists idempotency_key uuid"
    )
    op.execute(
        "create unique index if not exists uq_progress_photos_user_idem "
        "on progress_photos (user_key, idempotency_key) "
        "where idempotency_key is not null"
    )


def downgrade() -> None:
    op.execute("drop index if exists uq_progress_photos_user_idem")
    op.execute("alter table progress_photos drop column if exists idempotency_key")
