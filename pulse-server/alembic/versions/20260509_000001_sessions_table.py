"""Add sessions table for Google OAuth bearer auth.

Revision ID: 20260509_000001
Revises: 20260508_000001
Create Date: 2026-05-09T00:00:00Z
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260509_000001"
down_revision = "20260508_000001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "sessions",
        sa.Column("token_hash", sa.LargeBinary(), nullable=False),
        sa.Column("email", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("token_hash"),
    )
    op.create_index("idx_sessions_email", "sessions", ["email"], unique=False)
    op.create_index("idx_sessions_expires_at", "sessions", ["expires_at"], unique=False)


def downgrade() -> None:
    op.drop_index("idx_sessions_expires_at", table_name="sessions")
    op.drop_index("idx_sessions_email", table_name="sessions")
    op.drop_table("sessions")
