from __future__ import annotations

import os
from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool

from nutrition_server.db import to_sqlalchemy_url
from nutrition_server.repositories.tables import metadata

config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)


# Summary: Configures Alembic with DATABASE_URL when present in the process environment.
# Parameters:
# - None: Reads DATABASE_URL from process environment and updates Alembic config in-place.
# Returns:
# - None: Mutates Alembic config to ensure migration engine uses runtime database settings.
# Raises/Throws:
# - None: Missing DATABASE_URL leaves alembic.ini fallback URL unchanged.
def _configure_database_url() -> None:
    database_url = os.getenv("DATABASE_URL")
    if database_url:
        config.set_main_option("sqlalchemy.url", to_sqlalchemy_url(database_url))


# Summary: Runs Alembic migrations in offline mode using SQL script generation.
# Parameters:
# - None: Pulls URL and metadata from Alembic configuration and repository tables metadata.
# Returns:
# - None: Executes migration context and emits SQL without opening DB connections.
# Raises/Throws:
# - sqlalchemy.exc.SQLAlchemyError: Raised when migration context configuration fails.
def run_migrations_offline() -> None:
    _configure_database_url()
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )

    with context.begin_transaction():
        context.run_migrations()


# Summary: Runs Alembic migrations in online mode against an active database connection.
# Parameters:
# - None: Pulls engine settings from Alembic config and repository tables metadata.
# Returns:
# - None: Executes migration context against live database connection.
# Raises/Throws:
# - sqlalchemy.exc.SQLAlchemyError: Raised when engine creation or migration execution fails.
def run_migrations_online() -> None:
    _configure_database_url()
    section = config.get_section(config.config_ini_section) or {}
    connectable = engine_from_config(
        section,
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=metadata)

        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
