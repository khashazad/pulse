"""Add meal_id and meal_name to food_entries.

Revision ID: 20260510_000001
Revises: 20260509_000001
Create Date: 2026-05-10T00:00:00Z
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "20260510_000001"
down_revision = "20260509_000001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "food_entries",
        sa.Column("meal_id", postgresql.UUID(as_uuid=True), nullable=True),
    )
    op.add_column(
        "food_entries",
        sa.Column("meal_name", sa.Text(), nullable=True),
    )
    op.create_foreign_key(
        "fk_food_entries_meal_id",
        "food_entries",
        "meals",
        ["meal_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_index(
        "idx_food_entries_meal_id",
        "food_entries",
        ["meal_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("idx_food_entries_meal_id", table_name="food_entries")
    op.drop_constraint("fk_food_entries_meal_id", "food_entries", type_="foreignkey")
    op.drop_column("food_entries", "meal_name")
    op.drop_column("food_entries", "meal_id")
