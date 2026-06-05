"""Add auth_exchange_codes table for PKCE OAuth code exchange.

Backs the one-time-code + PKCE redemption flow that replaces returning the
bearer session token directly in the app redirect URL.

Revision ID: 20260524_000001
Revises: 20260519_000001
Create Date: 2026-05-24T00:00:00Z
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "20260524_000001"
down_revision = "20260519_000001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "auth_exchange_codes",
        sa.Column("code_hash", sa.LargeBinary(), nullable=False),
        sa.Column("email", sa.Text(), nullable=False),
        sa.Column("code_challenge", sa.Text(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("code_hash"),
    )
    op.create_index(
        "idx_auth_exchange_codes_expires_at",
        "auth_exchange_codes",
        ["expires_at"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("idx_auth_exchange_codes_expires_at", table_name="auth_exchange_codes")
    op.drop_table("auth_exchange_codes")
