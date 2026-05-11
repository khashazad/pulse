"""Add containers table.

Revision ID: 20260508_000001
Revises: 20260506_000001
Create Date: 2026-05-08T00:00:00Z
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "20260508_000001"
down_revision = "20260506_000001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "containers",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            primary_key=True,
            nullable=False,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column("user_key", sa.Text(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("normalized_name", sa.Text(), nullable=False),
        sa.Column("tare_weight_g", sa.Numeric(), nullable=False),
        sa.Column("photo", sa.LargeBinary(), nullable=True),
        sa.Column("photo_thumb", sa.LargeBinary(), nullable=True),
        sa.Column("photo_mime", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.CheckConstraint("tare_weight_g > 0", name="containers_tare_weight_g_check"),
    )
    op.create_index(
        "idx_containers_user_key_name",
        "containers",
        ["user_key", "normalized_name"],
        unique=True,
    )
    op.create_index("idx_containers_user_key", "containers", ["user_key"], unique=False)


def downgrade() -> None:
    op.drop_index("idx_containers_user_key", table_name="containers")
    op.drop_index("idx_containers_user_key_name", table_name="containers")
    op.drop_table("containers")
