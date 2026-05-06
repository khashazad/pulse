"""Add meals, custom_foods, food_memory; allow custom-food food_entries.

Revision ID: 20260506_000001
Revises: 20260406_000001
Create Date: 2026-05-06T00:00:00Z
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "20260506_000001"
down_revision = "20260406_000001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "custom_foods",
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
        sa.Column("basis", sa.Text(), nullable=False),
        sa.Column("serving_size", sa.Numeric(), nullable=True),
        sa.Column("serving_size_unit", sa.Text(), nullable=True),
        sa.Column("calories", sa.Integer(), nullable=False),
        sa.Column("protein_g", sa.Numeric(), nullable=False),
        sa.Column("carbs_g", sa.Numeric(), nullable=False),
        sa.Column("fat_g", sa.Numeric(), nullable=False),
        sa.Column("source", sa.Text(), nullable=False, server_default=sa.text("'manual'")),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.CheckConstraint(
            "basis in ('per_100g','per_serving','per_unit')",
            name="custom_foods_basis_check",
        ),
        sa.CheckConstraint(
            "source in ('manual','photo','corrected')",
            name="custom_foods_source_check",
        ),
    )
    op.create_index("idx_custom_foods_user_key_name", "custom_foods", ["user_key", "normalized_name"], unique=True)
    op.create_index("idx_custom_foods_user_key", "custom_foods", ["user_key"], unique=False)

    op.create_table(
        "food_memory",
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
        sa.Column("usda_fdc_id", sa.BigInteger(), nullable=True),
        sa.Column("usda_description", sa.Text(), nullable=True),
        sa.Column(
            "custom_food_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("custom_foods.id", ondelete="CASCADE"),
            nullable=True,
        ),
        sa.Column("basis", sa.Text(), nullable=True),
        sa.Column("serving_size", sa.Numeric(), nullable=True),
        sa.Column("serving_size_unit", sa.Text(), nullable=True),
        sa.Column("calories", sa.Integer(), nullable=True),
        sa.Column("protein_g", sa.Numeric(), nullable=True),
        sa.Column("carbs_g", sa.Numeric(), nullable=True),
        sa.Column("fat_g", sa.Numeric(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.CheckConstraint(
            "(usda_fdc_id is not null and custom_food_id is null) or "
            "(usda_fdc_id is null and custom_food_id is not null)",
            name="food_memory_one_target",
        ),
    )
    op.create_index("idx_food_memory_user_key_name", "food_memory", ["user_key", "normalized_name"], unique=True)
    op.create_index("idx_food_memory_user_key", "food_memory", ["user_key"], unique=False)

    op.create_table(
        "meals",
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
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
    )
    op.create_index("idx_meals_user_key_name", "meals", ["user_key", "normalized_name"], unique=True)
    op.create_index("idx_meals_user_key", "meals", ["user_key"], unique=False)

    op.create_table(
        "meal_items",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            primary_key=True,
            nullable=False,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column(
            "meal_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("meals.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("display_name", sa.Text(), nullable=False),
        sa.Column("quantity_text", sa.Text(), nullable=False),
        sa.Column("normalized_quantity_value", sa.Numeric(), nullable=True),
        sa.Column("normalized_quantity_unit", sa.Text(), nullable=True),
        sa.Column("usda_fdc_id", sa.BigInteger(), nullable=True),
        sa.Column("usda_description", sa.Text(), nullable=True),
        sa.Column(
            "custom_food_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("custom_foods.id", ondelete="RESTRICT"),
            nullable=True,
        ),
        sa.Column("calories", sa.Integer(), nullable=False),
        sa.Column("protein_g", sa.Numeric(), nullable=False),
        sa.Column("carbs_g", sa.Numeric(), nullable=False),
        sa.Column("fat_g", sa.Numeric(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.CheckConstraint(
            "(usda_fdc_id is not null and custom_food_id is null) or "
            "(usda_fdc_id is null and custom_food_id is not null)",
            name="meal_items_one_source",
        ),
    )
    op.create_index("idx_meal_items_meal_id", "meal_items", ["meal_id", "position"], unique=False)

    op.add_column(
        "food_entries",
        sa.Column(
            "custom_food_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("custom_foods.id", ondelete="RESTRICT"),
            nullable=True,
        ),
    )
    op.alter_column("food_entries", "usda_fdc_id", nullable=True)
    op.alter_column("food_entries", "usda_description", nullable=True)
    op.create_check_constraint(
        "food_entries_one_source",
        "food_entries",
        "(usda_fdc_id is not null and custom_food_id is null) or "
        "(usda_fdc_id is null and custom_food_id is not null)",
    )
    op.create_index("idx_food_entries_custom_food_id", "food_entries", ["custom_food_id"], unique=False)


def downgrade() -> None:
    op.drop_index("idx_food_entries_custom_food_id", table_name="food_entries")
    op.drop_constraint("food_entries_one_source", "food_entries", type_="check")
    op.alter_column("food_entries", "usda_description", nullable=False)
    op.alter_column("food_entries", "usda_fdc_id", nullable=False)
    op.drop_column("food_entries", "custom_food_id")

    op.drop_index("idx_meal_items_meal_id", table_name="meal_items")
    op.drop_table("meal_items")

    op.drop_index("idx_meals_user_key", table_name="meals")
    op.drop_index("idx_meals_user_key_name", table_name="meals")
    op.drop_table("meals")

    op.drop_index("idx_food_memory_user_key", table_name="food_memory")
    op.drop_index("idx_food_memory_user_key_name", table_name="food_memory")
    op.drop_table("food_memory")

    op.drop_index("idx_custom_foods_user_key", table_name="custom_foods")
    op.drop_index("idx_custom_foods_user_key_name", table_name="custom_foods")
    op.drop_table("custom_foods")
