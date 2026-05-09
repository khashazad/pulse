"""Create initial diet tracking schema.

Revision ID: 20260406_000001
Revises: 
Create Date: 2026-04-06T14:40:00Z
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision = "20260406_000001"
down_revision = None
branch_labels = None
depends_on = None


# Summary: Applies initial PostgreSQL tables and indexes required by the diet server.
# Parameters:
# - None: Uses Alembic operations context bound to active migration transaction.
# Returns:
# - None: Creates extension, tables, unique constraints, and supporting indexes.
# Raises/Throws:
# - sqlalchemy.exc.SQLAlchemyError: Raised when DDL execution fails.
def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")

    op.create_table(
        "daily_target_profile",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            primary_key=True,
            nullable=False,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column("user_key", sa.Text(), nullable=False),
        sa.Column("calories_target", sa.Integer(), nullable=False),
        sa.Column("protein_g_target", sa.Numeric(), nullable=False),
        sa.Column("carbs_g_target", sa.Numeric(), nullable=False),
        sa.Column("fat_g_target", sa.Numeric(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
    )
    op.create_index(
        "idx_daily_target_profile_user_key",
        "daily_target_profile",
        ["user_key"],
        unique=True,
    )

    op.create_table(
        "daily_logs",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, nullable=False),
        sa.Column("user_key", sa.Text(), nullable=False),
        sa.Column("log_date", sa.Date(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.UniqueConstraint("user_key", "log_date", name="uq_daily_logs_user_key_log_date"),
    )
    op.create_index("idx_daily_logs_user_key", "daily_logs", ["user_key"], unique=False)

    op.create_table(
        "food_entries",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            primary_key=True,
            nullable=False,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column(
            "daily_log_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("daily_logs.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("user_key", sa.Text(), nullable=False),
        sa.Column("entry_group_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("display_name", sa.Text(), nullable=False),
        sa.Column("quantity_text", sa.Text(), nullable=False),
        sa.Column("normalized_quantity_value", sa.Numeric(), nullable=True),
        sa.Column("normalized_quantity_unit", sa.Text(), nullable=True),
        sa.Column("usda_fdc_id", sa.BigInteger(), nullable=False),
        sa.Column("usda_description", sa.Text(), nullable=False),
        sa.Column("calories", sa.Integer(), nullable=False),
        sa.Column("protein_g", sa.Numeric(), nullable=False),
        sa.Column("carbs_g", sa.Numeric(), nullable=False),
        sa.Column("fat_g", sa.Numeric(), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
    )
    op.create_index("idx_food_entries_user_key", "food_entries", ["user_key"], unique=False)
    op.create_index(
        "idx_food_entries_daily_log_id_consumed_at",
        "food_entries",
        ["daily_log_id", "consumed_at"],
        unique=False,
    )


# Summary: Reverts the initial diet schema migration and drops all managed tables/indexes.
# Parameters:
# - None: Uses Alembic operations context bound to active migration transaction.
# Returns:
# - None: Drops created indexes and tables in reverse dependency order.
# Raises/Throws:
# - sqlalchemy.exc.SQLAlchemyError: Raised when DDL rollback execution fails.
def downgrade() -> None:
    op.drop_index("idx_food_entries_daily_log_id_consumed_at", table_name="food_entries")
    op.drop_index("idx_food_entries_user_key", table_name="food_entries")
    op.drop_table("food_entries")

    op.drop_index("idx_daily_logs_user_key", table_name="daily_logs")
    op.drop_table("daily_logs")

    op.drop_index("idx_daily_target_profile_user_key", table_name="daily_target_profile")
    op.drop_table("daily_target_profile")
