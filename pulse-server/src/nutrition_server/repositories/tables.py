from __future__ import annotations

from sqlalchemy import BigInteger, Column, Date, DateTime, ForeignKey, Index, Integer, MetaData, Numeric, Table
from sqlalchemy import Text, UniqueConstraint, func, text
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
    Column("usda_fdc_id", BigInteger, nullable=False),
    Column("usda_description", Text, nullable=False),
    Column("calories", Integer, nullable=False),
    Column("protein_g", Numeric, nullable=False),
    Column("carbs_g", Numeric, nullable=False),
    Column("fat_g", Numeric, nullable=False),
    Column("consumed_at", DateTime(timezone=True), nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Index("idx_food_entries_user_key", "user_key"),
    Index("idx_food_entries_daily_log_id_consumed_at", "daily_log_id", "consumed_at"),
)

food_aliases = Table(
    "food_aliases",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")),
    Column("user_key", Text, nullable=False),
    Column("alias_text", Text, nullable=False),
    Column("preferred_label", Text, nullable=False),
    Column("default_quantity_value", Numeric, nullable=True),
    Column("default_quantity_unit", Text, nullable=True),
    Column("preferred_usda_fdc_id", BigInteger, nullable=False),
    Column("preferred_usda_description", Text, nullable=False),
    Column("confidence_score", Numeric, nullable=False, server_default=text("0")),
    Column("last_confirmed_at", DateTime(timezone=True), nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    UniqueConstraint("user_key", "alias_text", name="uq_food_aliases_user_key_alias_text"),
    Index("idx_food_aliases_user_key", "user_key"),
)

food_match_history = Table(
    "food_match_history",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")),
    Column("user_key", Text, nullable=False),
    Column("raw_phrase", Text, nullable=False),
    Column("quantity_text", Text, nullable=True),
    Column("usda_fdc_id", BigInteger, nullable=False),
    Column("usda_description", Text, nullable=False),
    Column("times_confirmed", Integer, nullable=False, server_default=text("1")),
    Column("last_confirmed_at", DateTime(timezone=True), nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Index("idx_food_match_history_user_key", "user_key"),
    Index(
        "idx_food_match_history_match_key",
        "user_key",
        "raw_phrase",
        text("coalesce(quantity_text, '')"),
        "usda_fdc_id",
        unique=True,
    ),
)
