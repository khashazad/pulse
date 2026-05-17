"""SQLAlchemy-Core table definitions for the diet-tracker Postgres schema.

Declares every ``Table`` object referenced by the repositories layer using a
single shared :class:`MetaData`. There are no ORM mappings — repositories build
queries directly against these table objects. ``bootstrap_schema()`` (in
``db.py``) keeps the live database in sync by executing ``schema.sql`` on
startup; this module is the canonical Python-side representation of that schema.

Tables defined here:

- ``daily_target_profile`` — per-user macro and weight targets.
- ``daily_logs`` — one row per ``(user_key, log_date)`` aggregating a day's intake.
- ``custom_foods`` — user-defined foods with stored macros at a chosen basis.
- ``food_memory`` — per-user lookup table mapping a phrase to either a USDA food
  or a custom food (with alias array support).
- ``meals`` / ``meal_items`` — saved meals and their pre-scaled component items.
- ``food_entries`` — individual logged entries belonging to a daily log.
- ``sessions`` — Bearer-token session store keyed by SHA-256 token hash.
- ``containers`` — reusable container tares with optional photo blobs.
- ``weight_entries`` — one weight reading per ``(user_key, log_date)``.
- ``progress_photos`` — per-day progress-photo blobs keyed by slot.

Every table is scoped by ``user_key`` so the same schema supports the
multi-user model while the legacy single-user deployment uses one fixed key.
"""

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
    LargeBinary,
    MetaData,
    Numeric,
    Table,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import ARRAY, UUID

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
    Column("target_weight_lb", Numeric, nullable=True),
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
    Column("aliases", ARRAY(Text), nullable=False, server_default=text("'{}'::text[]")),
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
    Column("aliases", ARRAY(Text), nullable=False, server_default=text("'{}'::text[]")),
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
    Column(
        "meal_id",
        UUID(as_uuid=True),
        ForeignKey("meals.id", ondelete="SET NULL"),
        nullable=True,
    ),
    Column("meal_name", Text, nullable=True),
    CheckConstraint(
        "(usda_fdc_id is not null and custom_food_id is null) or "
        "(usda_fdc_id is null and custom_food_id is not null)",
        name="food_entries_one_source",
    ),
    Index("idx_food_entries_user_key", "user_key"),
    Index("idx_food_entries_daily_log_id_consumed_at", "daily_log_id", "consumed_at"),
    Index("idx_food_entries_custom_food_id", "custom_food_id"),
    Index("idx_food_entries_meal_id", "meal_id"),
)

sessions = Table(
    "sessions",
    metadata,
    Column("token_hash", LargeBinary, primary_key=True),
    Column("email", Text, nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("last_used_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("expires_at", DateTime(timezone=True), nullable=False),
    Index("idx_sessions_email", "email"),
    Index("idx_sessions_expires_at", "expires_at"),
)

containers = Table(
    "containers",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")),
    Column("user_key", Text, nullable=False),
    Column("name", Text, nullable=False),
    Column("normalized_name", Text, nullable=False),
    Column("tare_weight_g", Numeric, nullable=False),
    Column("photo", LargeBinary, nullable=True),
    Column("photo_thumb", LargeBinary, nullable=True),
    Column("photo_mime", Text, nullable=True),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    CheckConstraint("tare_weight_g > 0", name="containers_tare_weight_g_check"),
    Index("idx_containers_user_key_name", "user_key", "normalized_name", unique=True),
    Index("idx_containers_user_key", "user_key"),
)

weight_entries = Table(
    "weight_entries",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")),
    Column("user_key", Text, nullable=False),
    Column("log_date", Date, nullable=False),
    Column("weight_lb", Numeric(6, 2), nullable=False),
    Column("source_unit", Text, nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    CheckConstraint("weight_lb > 0", name="weight_entries_weight_lb_check"),
    CheckConstraint("source_unit in ('lb','kg')", name="weight_entries_source_unit_check"),
    UniqueConstraint("user_key", "log_date", name="uq_weight_entries_user_key_log_date"),
    Index("idx_weight_entries_user_key_log_date", "user_key", "log_date"),
)

progress_photos = Table(
    "progress_photos",
    metadata,
    Column("id", UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")),
    Column("user_key", Text, nullable=False),
    Column("log_date", Date, nullable=False),
    Column("slot", Text, nullable=False),
    Column("photo", LargeBinary, nullable=False),
    Column("photo_thumb", LargeBinary, nullable=False),
    Column("photo_mime", Text, nullable=False, server_default=text("'image/jpeg'")),
    Column("bytes", Integer, nullable=False),
    Column("sha256", Text, nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    Column("updated_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
    CheckConstraint(
        "slot in ('front','left','right','back')",
        name="progress_photos_slot_check",
    ),
    UniqueConstraint("user_key", "log_date", "slot", name="uq_progress_photos_user_date_slot"),
    Index("idx_progress_photos_user_date", "user_key", "log_date"),
)
