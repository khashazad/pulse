from __future__ import annotations

from sqlalchemy import BigInteger, Date, DateTime, ForeignKey, Integer, MetaData, Numeric, Table
from sqlalchemy import Column, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.sql import func

metadata = MetaData()

daily_target_profile = Table(
    "daily_target_profile",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True),
    Column("user_key", Text, nullable=False),
    Column("calories_target", Integer, nullable=False),
    Column("protein_g_target", Numeric, nullable=False),
    Column("carbs_g_target", Numeric, nullable=False),
    Column("fat_g_target", Numeric, nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
)

daily_logs = Table(
    "daily_logs",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True),
    Column("user_key", Text, nullable=False),
    Column("log_date", Date, nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
)

food_entries = Table(
    "food_entries",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True),
    Column("daily_log_id", UUID(as_uuid=True), ForeignKey("daily_logs.id", ondelete="CASCADE"), nullable=False),
    Column("user_key", Text, nullable=False),
    Column("source_message_id", Text, nullable=True),
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
)

food_aliases = Table(
    "food_aliases",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True),
    Column("user_key", Text, nullable=False),
    Column("alias_text", Text, nullable=False),
    Column("preferred_label", Text, nullable=False),
    Column("default_quantity_value", Numeric, nullable=True),
    Column("default_quantity_unit", Text, nullable=True),
    Column("preferred_usda_fdc_id", BigInteger, nullable=False),
    Column("preferred_usda_description", Text, nullable=False),
    Column("confidence_score", Numeric, nullable=False, server_default="0"),
    Column("last_confirmed_at", DateTime(timezone=True), nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
)

food_match_history = Table(
    "food_match_history",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True),
    Column("user_key", Text, nullable=False),
    Column("raw_phrase", Text, nullable=False),
    Column("quantity_text", Text, nullable=True),
    Column("usda_fdc_id", BigInteger, nullable=False),
    Column("usda_description", Text, nullable=False),
    Column("times_confirmed", Integer, nullable=False, server_default="1"),
    Column("last_confirmed_at", DateTime(timezone=True), nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
)
