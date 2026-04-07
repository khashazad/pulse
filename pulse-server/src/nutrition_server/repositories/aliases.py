from __future__ import annotations

from datetime import datetime as DateTimeValue
from typing import Any

from sqlalchemy import bindparam, literal_column, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from nutrition_server.repositories.tables import food_aliases
from nutrition_server.sql_like import escape_like_query


class AliasesRepository:
    # Summary: Initializes an aliases repository bound to an active SQLAlchemy session.
    # Parameters:
    # - session (AsyncSession): SQLAlchemy async session used for all repository operations.
    # Returns:
    # - None: Stores the session for subsequent method calls.
    # Raises/Throws:
    # - None: Initialization only stores references and performs no I/O.
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    # Summary: Searches alias rows by phrase fragment ordered by confidence and recency.
    # Parameters:
    # - user_key (str): User identifier whose alias mappings are queried.
    # - query (str): Case-insensitive phrase fragment used for ILIKE matching.
    # Returns:
    # - list[dict[str, Any]]: Ranked alias rows matching the query.
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    async def search_aliases(self, user_key: str, query: str) -> list[dict[str, Any]]:
        escaped_query = escape_like_query(query)
        pattern = f"%{escaped_query}%"
        stmt = (
            select(*food_aliases.c)
            .where(food_aliases.c.user_key == user_key)
            .where(food_aliases.c.alias_text.ilike(bindparam("alias_pattern"), escape="\\"))
            .order_by(food_aliases.c.confidence_score.desc(), food_aliases.c.last_confirmed_at.desc())
            .limit(10)
        )
        result = await self._session.execute(stmt, {"alias_pattern": pattern})
        return [dict(row) for row in result.mappings().all()]

    # Summary: Inserts or updates an alias row and returns both row data and created/update state.
    # Parameters:
    # - user_key (str): User identifier owning the alias mapping.
    # - alias_text (str): User-entered phrase mapped to a preferred USDA item.
    # - preferred_label (str): Display label preferred for the alias.
    # - preferred_usda_fdc_id (int): USDA FDC identifier associated with the alias.
    # - preferred_usda_description (str): USDA description associated with the alias.
    # - default_quantity_value (float | None): Default numeric quantity for the alias.
    # - default_quantity_unit (str | None): Default unit associated with default quantity.
    # - confirmed_at (DateTimeValue): Timestamp used for last-confirmed bookkeeping.
    # - updated_at (DateTimeValue): Timestamp used for update bookkeeping.
    # - increment_confidence (bool): Whether conflicting rows should increment confidence score.
    # Returns:
    # - tuple[dict[str, Any], bool]: Persisted alias row and whether the row was newly inserted.
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    async def create_or_update_alias_with_state(
        self,
        user_key: str,
        alias_text: str,
        preferred_label: str,
        preferred_usda_fdc_id: int,
        preferred_usda_description: str,
        default_quantity_value: float | None,
        default_quantity_unit: str | None,
        confirmed_at: DateTimeValue,
        updated_at: DateTimeValue,
        increment_confidence: bool,
    ) -> tuple[dict[str, Any], bool]:
        stmt = pg_insert(food_aliases).values(
            user_key=user_key,
            alias_text=alias_text,
            preferred_label=preferred_label,
            default_quantity_value=default_quantity_value,
            default_quantity_unit=default_quantity_unit,
            preferred_usda_fdc_id=preferred_usda_fdc_id,
            preferred_usda_description=preferred_usda_description,
            confidence_score=1.0,
            last_confirmed_at=confirmed_at,
            updated_at=updated_at,
        )

        update_values: dict[str, Any] = {
            "preferred_label": stmt.excluded.preferred_label,
            "default_quantity_value": stmt.excluded.default_quantity_value,
            "default_quantity_unit": stmt.excluded.default_quantity_unit,
            "preferred_usda_fdc_id": stmt.excluded.preferred_usda_fdc_id,
            "preferred_usda_description": stmt.excluded.preferred_usda_description,
            "last_confirmed_at": stmt.excluded.last_confirmed_at,
            "updated_at": stmt.excluded.updated_at,
        }
        if increment_confidence:
            update_values["confidence_score"] = food_aliases.c.confidence_score + 1

        stmt = stmt.on_conflict_do_update(
            index_elements=[food_aliases.c.user_key, food_aliases.c.alias_text],
            set_=update_values,
        ).returning(*food_aliases.c, literal_column("xmax = 0").label("created"))

        result = await self._session.execute(stmt)
        row = result.mappings().one()
        created = bool(row["created"])
        persisted_row = {key: value for key, value in row.items() if key != "created"}
        return persisted_row, created

    # Summary: Inserts or updates an alias row and optionally increments confidence on conflicts.
    # Parameters:
    # - user_key (str): User identifier owning the alias mapping.
    # - alias_text (str): User-entered phrase mapped to a preferred USDA item.
    # - preferred_label (str): Display label preferred for the alias.
    # - preferred_usda_fdc_id (int): USDA FDC identifier associated with the alias.
    # - preferred_usda_description (str): USDA description associated with the alias.
    # - default_quantity_value (float | None): Default numeric quantity for the alias.
    # - default_quantity_unit (str | None): Default unit associated with default quantity.
    # - confirmed_at (DateTimeValue): Timestamp used for last-confirmed bookkeeping.
    # - updated_at (DateTimeValue): Timestamp used for update bookkeeping.
    # - increment_confidence (bool): Whether conflicting rows should increment confidence score.
    # Returns:
    # - dict[str, Any]: Persisted alias row after insert/upsert resolution.
    # Raises/Throws:
    # - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    async def create_or_update_alias(
        self,
        user_key: str,
        alias_text: str,
        preferred_label: str,
        preferred_usda_fdc_id: int,
        preferred_usda_description: str,
        default_quantity_value: float | None,
        default_quantity_unit: str | None,
        confirmed_at: DateTimeValue,
        updated_at: DateTimeValue,
        increment_confidence: bool,
    ) -> dict[str, Any]:
        row, _ = await self.create_or_update_alias_with_state(
            user_key=user_key,
            alias_text=alias_text,
            preferred_label=preferred_label,
            preferred_usda_fdc_id=preferred_usda_fdc_id,
            preferred_usda_description=preferred_usda_description,
            default_quantity_value=default_quantity_value,
            default_quantity_unit=default_quantity_unit,
            confirmed_at=confirmed_at,
            updated_at=updated_at,
            increment_confidence=increment_confidence,
        )
        return row
