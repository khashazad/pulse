from __future__ import annotations

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    Column,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    MetaData,
    Numeric,
    Table,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import UUID

metadata = MetaData()

daily_target_profile = Table(
    "daily_target_profile",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")),
    Column("user_key", Text, nullable=False),
    Column("calories_target", Integer, nullable=False),
    Column("protein_g_target", Numeric, nullable=False),
    Column("carbs_g_target", Numeric, nullable=False),
    Column("fat_g_target", Numeric, nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Index("idx_daily_target_profile_user_key", "user_key", unique=True),
)

daily_logs = Table(
    "daily_logs",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True),
    Column("user_key", Text, nullable=False),
    Column("log_date", Date, nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    UniqueConstraint("user_key", "log_date", name="uq_daily_logs_user_key_log_date"),
    Index("idx_daily_logs_user_key", "user_key"),
)

custom_foods = Table(
    "custom_foods",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")),
    Column("user_key", Text, nullable=False),
    Column("name", Text, nullable=False),
    Column("normalized_name", Text, nullable=False),
    Column("basis", Text, nullable=False),
    Column("serving_size", Numeric, nullable=True),
    Column("serving_size_unit", Text, nullable=True),
    Column("calories", Integer, nullable=False),
    Column("protein_g", Numeric, nullable=False),
    Column("carbs_g", Numeric, nullable=False),
    Column("fat_g", Numeric, nullable=False),
    Column("source", Text, nullable=False, server_default=text("'manual'")),
    Column("notes", Text, nullable=True),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    CheckConstraint("basis in ('per_100g','per_serving','per_unit')", name="custom_foods_basis_check"),
    CheckConstraint("source in ('manual','photo','corrected')", name="custom_foods_source_check"),
    Index("idx_custom_foods_user_key_name", "user_key", "normalized_name", unique=True),
    Index("idx_custom_foods_user_key", "user_key"),
)

food_memory = Table(
    "food_memory",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")),
    Column("user_key", Text, nullable=False),
    Column("name", Text, nullable=False),
    Column("normalized_name", Text, nullable=False),
    Column("usda_fdc_id", BigInteger, nullable=True),
    Column("usda_description", Text, nullable=True),
    Column(
        "custom_food_id",
        UUID(as_uuid=True),
        ForeignKey("custom_foods.id", ondelete="CASCADE"),
        nullable=True,
    ),
    Column("basis", Text, nullable=True),
    Column("serving_size", Numeric, nullable=True),
    Column("serving_size_unit", Text, nullable=True),
    Column("calories", Integer, nullable=True),
    Column("protein_g", Numeric, nullable=True),
    Column("carbs_g", Numeric, nullable=True),
    Column("fat_g", Numeric, nullable=True),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    CheckConstraint(
        "(usda_fdc_id is not null and custom_food_id is null) or "
        "(usda_fdc_id is null and custom_food_id is not null)",
        name="food_memory_one_target",
    ),
    Index("idx_food_memory_user_key_name", "user_key", "normalized_name", unique=True),
    Index("idx_food_memory_user_key", "user_key"),
)

meals = Table(
    "meals",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")),
    Column("user_key", Text, nullable=False),
    Column("name", Text, nullable=False),
    Column("normalized_name", Text, nullable=False),
    Column("notes", Text, nullable=True),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Index("idx_meals_user_key_name", "user_key", "normalized_name", unique=True),
    Index("idx_meals_user_key", "user_key"),
)

meal_items = Table(
    "meal_items",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")),
    Column("meal_id", UUID(as_uuid=True), ForeignKey("meals.id", ondelete="CASCADE"), nullable=False),
    Column("position", Integer, nullable=False),
    Column("display_name", Text, nullable=False),
    Column("quantity_text", Text, nullable=False),
    Column("normalized_quantity_value", Numeric, nullable=True),
    Column("normalized_quantity_unit", Text, nullable=True),
    Column("usda_fdc_id", BigInteger, nullable=True),
    Column("usda_description", Text, nullable=True),
    Column(
        "custom_food_id",
        UUID(as_uuid=True),
        ForeignKey("custom_foods.id", ondelete="RESTRICT"),
        nullable=True,
    ),
    Column("calories", Integer, nullable=False),
    Column("protein_g", Numeric, nullable=False),
    Column("carbs_g", Numeric, nullable=False),
    Column("fat_g", Numeric, nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    CheckConstraint(
        "(usda_fdc_id is not null and custom_food_id is null) or "
        "(usda_fdc_id is null and custom_food_id is not null)",
        name="meal_items_one_source",
    ),
    Index("idx_meal_items_meal_id", "meal_id", "position"),
)

food_entries = Table(
    "food_entries",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")),
    Column("daily_log_id", UUID(as_uuid=True), ForeignKey("daily_logs.id", ondelete="CASCADE"), nullable=False),
    Column("user_key", Text, nullable=False),
    Column("entry_group_id", UUID(as_uuid=True), nullable=False),
    Column("display_name", Text, nullable=False),
    Column("quantity_text", Text, nullable=False),
    Column("normalized_quantity_value", Numeric, nullable=True),
    Column("normalized_quantity_unit", Text, nullable=True),
    Column("usda_fdc_id", BigInteger, nullable=True),
    Column("usda_description", Text, nullable=True),
    Column(
        "custom_food_id",
        UUID(as_uuid=True),
        ForeignKey("custom_foods.id", ondelete="RESTRICT"),
        nullable=True,
    ),
    Column("calories", Integer, nullable=False),
    Column("protein_g", Numeric, nullable=False),
    Column("carbs_g", Numeric, nullable=False),
    Column("fat_g", Numeric, nullable=False),
    Column("consumed_at", DateTime(timezone=True), nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    CheckConstraint(
        "(usda_fdc_id is not null and custom_food_id is null) or "
        "(usda_fdc_id is null and custom_food_id is not null)",
        name="food_entries_one_source",
    ),
    Index("idx_food_entries_user_key", "user_key"),
    Index("idx_food_entries_daily_log_id_consumed_at", "daily_log_id", "consumed_at"),
    Index("idx_food_entries_custom_food_id", "custom_food_id"),
)
