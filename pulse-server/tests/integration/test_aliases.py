"""Integration tests for food-memory and meal alias handling.

Exercises the ``aliases`` column on ``food_memory`` and ``meals``: insertion of
ARRAY[text] values, the DB-level CHECK/trigger guards that reject aliases equal
to a row's own name or overlapping another row's canonical/aliases, and the
repository + service helpers that read aliases (``get_by_name`` matching,
``list_meals`` projection, ``add_alias``/``remove_alias`` mutations, alias
collision pre-check, and ``upsert_usda``'s preservation semantics when aliases
are omitted). Integration test: hits a real Postgres via ``TEST_DATABASE_URL``.
"""

from __future__ import annotations

import os
import uuid
from datetime import datetime as DateTimeValue
from datetime import timezone as TimezoneValue

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from pulse_server.db import to_sqlalchemy_url

pytestmark = pytest.mark.integration


def _integration_database_url() -> str:
    """Resolve the SQLAlchemy URL for the integration database, skipping if unset.

    **Outputs:**
    - str: SQLAlchemy-async URL derived from ``TEST_DATABASE_URL``.

    **Exceptions:**
    - ``pytest.skip.Exception``: Raised via ``pytest.skip`` when ``TEST_DATABASE_URL`` is not set.
    """
    raw_url = os.getenv("TEST_DATABASE_URL")
    if raw_url is None:
        pytest.skip("Set TEST_DATABASE_URL to run integration tests")
    return to_sqlalchemy_url(raw_url)


async def _truncate(engine) -> None:
    """Truncate all tables touched by this suite, restarting identity sequences.

    **Inputs:**
    - engine: SQLAlchemy async engine bound to the integration database.
    """
    async with engine.begin() as conn:
        await conn.exec_driver_sql(
            "TRUNCATE TABLE food_entries, meal_items, meals, food_memory, custom_foods, daily_logs, daily_target_profile RESTART IDENTITY CASCADE"
        )


@pytest_asyncio.fixture(scope="session")
async def session_factory():
    """Session-scoped async session factory bound to the integration engine.

    **Outputs:**
    - ``async_sessionmaker``: factory yielding ``AsyncSession`` instances.
    """
    engine = create_async_engine(_integration_database_url(), pool_pre_ping=True)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()


@pytest_asyncio.fixture(autouse=True)
async def clean_database(session_factory):
    """Auto-applied fixture that truncates suite tables before and after each test.

    **Inputs:**
    - session_factory: session-scoped factory whose bound engine drives truncation.
    """
    await _truncate(session_factory.kw["bind"])
    yield
    await _truncate(session_factory.kw["bind"])


@pytest_asyncio.fixture
async def session(session_factory):
    """Per-test async session opened from the shared factory.

    **Inputs:**
    - session_factory: shared ``async_sessionmaker`` fixture.

    **Outputs:**
    - ``AsyncSession``: open session, closed when the test completes.
    """
    async with session_factory() as s:
        yield s


@pytest.mark.asyncio
async def test_food_memory_has_aliases_column(session: AsyncSession) -> None:
    """``food_memory.aliases`` accepts and round-trips a ``text[]`` value."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, aliases, created_at, updated_at) "
            "values (:uk, 'PB', 'pb', 1, 'PB', 'per_100g', 100, 1, 1, 1, ARRAY['peanut butter']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    row = (await session.execute(
        text("select aliases from food_memory where user_key = :uk"),
        {"uk": user_key},
    )).mappings().first()
    assert row is not None
    assert list(row["aliases"]) == ["peanut butter"]


@pytest.mark.asyncio
async def test_meals_has_aliases_column(session: AsyncSession) -> None:
    """``meals.aliases`` accepts and round-trips a ``text[]`` value."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into meals (user_key, name, normalized_name, aliases, created_at, updated_at) "
            "values (:uk, 'Wrap', 'wrap', ARRAY['the wrap']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    row = (await session.execute(
        text("select aliases from meals where user_key = :uk"),
        {"uk": user_key},
    )).mappings().first()
    assert row is not None
    assert list(row["aliases"]) == ["the wrap"]


@pytest.mark.asyncio
async def test_food_memory_check_rejects_alias_equal_to_name(session: AsyncSession) -> None:
    """CHECK constraint rejects a ``food_memory`` row whose alias equals its own normalized name."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    with pytest.raises(IntegrityError):
        await session.execute(
            text(
                "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, aliases, created_at, updated_at) "
                "values (:uk, 'PB', 'pb', 1, 'PB', 'per_100g', 100, 1, 1, 1, ARRAY['pb']::text[], :now, :now)"
            ),
            {"uk": user_key, "now": now},
        )
        await session.commit()


@pytest.mark.asyncio
async def test_food_memory_trigger_rejects_alias_equal_to_other_canonical(session: AsyncSession) -> None:
    """Trigger rejects an alias that collides with another ``food_memory`` row's canonical name."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, created_at, updated_at) "
            "values (:uk, 'Peanut Butter', 'peanut butter', 1, 'PB', 'per_100g', 100, 1, 1, 1, :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()
    with pytest.raises(IntegrityError):
        await session.execute(
            text(
                "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, aliases, created_at, updated_at) "
                "values (:uk, 'Almond Butter', 'almond butter', 2, 'AB', 'per_100g', 100, 1, 1, 1, ARRAY['peanut butter']::text[], :now, :now)"
            ),
            {"uk": user_key, "now": now},
        )
        await session.commit()


@pytest.mark.asyncio
async def test_meals_trigger_rejects_alias_overlap(session: AsyncSession) -> None:
    """Trigger rejects a second meal whose aliases overlap an existing meal's aliases."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into meals (user_key, name, normalized_name, aliases, created_at, updated_at) "
            "values (:uk, 'Wrap A', 'wrap a', ARRAY['the wrap']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()
    with pytest.raises(IntegrityError):
        await session.execute(
            text(
                "insert into meals (user_key, name, normalized_name, aliases, created_at, updated_at) "
                "values (:uk, 'Wrap B', 'wrap b', ARRAY['the wrap']::text[], :now, :now)"
            ),
            {"uk": user_key, "now": now},
        )
        await session.commit()


from pulse_server.repositories.food_memory import FoodMemoryRepository
from pulse_server.repositories.meals import MealsRepository


@pytest.mark.asyncio
async def test_food_memory_get_by_name_matches_alias(session: AsyncSession) -> None:
    """``FoodMemoryRepository.get_by_name`` resolves a row through one of its aliases."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, aliases, created_at, updated_at) "
            "values (:uk, 'Peanut Butter', 'peanut butter', 1, 'PB', 'per_100g', 100, 1, 1, 1, ARRAY['pb', 'pbs']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    repo = FoodMemoryRepository(session)
    row = await repo.get_by_name(user_key=user_key, normalized_name="pb")
    assert row is not None
    assert row["normalized_name"] == "peanut butter"
    assert list(row["aliases"]) == ["pb", "pbs"]


@pytest.mark.asyncio
async def test_meals_get_by_name_matches_alias(session: AsyncSession) -> None:
    """``MealsRepository.get_meal_by_name`` resolves a meal through one of its aliases."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into meals (user_key, name, normalized_name, aliases, created_at, updated_at) "
            "values (:uk, 'Buffalo Chicken Wrap', 'buffalo chicken wrap', ARRAY['the wrap']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    repo = MealsRepository(session)
    row = await repo.get_meal_by_name(user_key=user_key, normalized_name="the wrap")
    assert row is not None
    assert row["normalized_name"] == "buffalo chicken wrap"
    assert list(row["aliases"]) == ["the wrap"]


@pytest.mark.asyncio
async def test_meals_list_includes_aliases(session: AsyncSession) -> None:
    """``MealsRepository.list_meals`` returns the ``aliases`` array on each row."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into meals (user_key, name, normalized_name, aliases, created_at, updated_at) "
            "values (:uk, 'Wrap', 'wrap', ARRAY['the wrap', 'lunch wrap']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    repo = MealsRepository(session)
    rows = await repo.list_meals(user_key=user_key)
    assert len(rows) == 1
    assert list(rows[0]["aliases"]) == ["the wrap", "lunch wrap"]


@pytest.mark.asyncio
async def test_food_memory_add_alias_appends(session: AsyncSession) -> None:
    """``FoodMemoryRepository.add_alias`` appends a new alias to an existing row."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, created_at, updated_at) "
            "values (:uk, 'Peanut Butter', 'peanut butter', 1, 'PB', 'per_100g', 100, 1, 1, 1, :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    repo = FoodMemoryRepository(session)
    updated = await repo.add_alias(
        user_key=user_key, normalized_name="peanut butter", alias="pb", now=now,
    )
    await session.commit()
    assert updated is not None
    assert list(updated["aliases"]) == ["pb"]


@pytest.mark.asyncio
async def test_food_memory_add_alias_idempotent(session: AsyncSession) -> None:
    """``FoodMemoryRepository.add_alias`` is a no-op when the alias is already present."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, aliases, created_at, updated_at) "
            "values (:uk, 'PB', 'peanut butter', 1, 'PB', 'per_100g', 100, 1, 1, 1, ARRAY['pb']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    repo = FoodMemoryRepository(session)
    updated = await repo.add_alias(
        user_key=user_key, normalized_name="peanut butter", alias="pb", now=now,
    )
    await session.commit()
    assert list(updated["aliases"]) == ["pb"]


@pytest.mark.asyncio
async def test_food_memory_remove_alias(session: AsyncSession) -> None:
    """``FoodMemoryRepository.remove_alias`` strips one alias and preserves the rest."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, aliases, created_at, updated_at) "
            "values (:uk, 'PB', 'peanut butter', 1, 'PB', 'per_100g', 100, 1, 1, 1, ARRAY['pb', 'pbs']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    repo = FoodMemoryRepository(session)
    updated = await repo.remove_alias(
        user_key=user_key, normalized_name="peanut butter", alias="pb", now=now,
    )
    await session.commit()
    assert list(updated["aliases"]) == ["pbs"]


@pytest.mark.asyncio
async def test_meals_add_alias_appends(session: AsyncSession) -> None:
    """``MealsRepository.add_alias`` appends a new alias to an existing meal."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    result = await session.execute(
        text(
            "insert into meals (user_key, name, normalized_name, created_at, updated_at) "
            "values (:uk, 'Wrap', 'wrap', :now, :now) returning id"
        ),
        {"uk": user_key, "now": now},
    )
    meal_id = result.scalar_one()
    await session.commit()

    repo = MealsRepository(session)
    updated = await repo.add_alias(
        meal_id=meal_id, user_key=user_key, alias="the wrap", now=now,
    )
    await session.commit()
    assert updated is not None
    assert list(updated["aliases"]) == ["the wrap"]


@pytest.mark.asyncio
async def test_meals_remove_alias(session: AsyncSession) -> None:
    """``MealsRepository.remove_alias`` removes a single alias from a meal's array."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    result = await session.execute(
        text(
            "insert into meals (user_key, name, normalized_name, aliases, created_at, updated_at) "
            "values (:uk, 'Wrap', 'wrap', ARRAY['the wrap', 'lunch']::text[], :now, :now) returning id"
        ),
        {"uk": user_key, "now": now},
    )
    meal_id = result.scalar_one()
    await session.commit()

    repo = MealsRepository(session)
    updated = await repo.remove_alias(
        meal_id=meal_id, user_key=user_key, alias="the wrap", now=now,
    )
    await session.commit()
    assert list(updated["aliases"]) == ["lunch"]


@pytest.mark.asyncio
async def test_food_memory_alias_collision_pre_check(session: AsyncSession) -> None:
    """``assert_food_alias_available`` raises ``ValueError`` for an alias colliding with an existing canonical name."""
    from pulse_server.services.food_memory_service import assert_food_alias_available

    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, created_at, updated_at) "
            "values (:uk, 'Almond Butter', 'almond butter', 2, 'AB', 'per_100g', 100, 1, 1, 1, :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    with pytest.raises(ValueError) as excinfo:
        await assert_food_alias_available(
            session=session,
            user_key=user_key,
            alias="almond butter",
            exclude_normalized_name=None,
        )
    assert "almond butter" in str(excinfo.value)


@pytest.mark.asyncio
async def test_food_memory_alias_collision_excludes_own_row(session: AsyncSession) -> None:
    """``assert_food_alias_available`` skips the row identified by ``exclude_normalized_name``."""
    from pulse_server.services.food_memory_service import assert_food_alias_available

    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    await session.execute(
        text(
            "insert into food_memory (user_key, name, normalized_name, usda_fdc_id, usda_description, basis, calories, protein_g, carbs_g, fat_g, aliases, created_at, updated_at) "
            "values (:uk, 'PB', 'peanut butter', 1, 'PB', 'per_100g', 100, 1, 1, 1, ARRAY['pb']::text[], :now, :now)"
        ),
        {"uk": user_key, "now": now},
    )
    await session.commit()

    await assert_food_alias_available(
        session=session,
        user_key=user_key,
        alias="pb",
        exclude_normalized_name="peanut butter",
    )


@pytest.mark.asyncio
async def test_remember_food_persists_aliases(session: AsyncSession) -> None:
    """``upsert_usda`` writes the provided ``aliases`` list and they round-trip via ``get_by_name``."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    repo = FoodMemoryRepository(session)
    await repo.upsert_usda(
        user_key=user_key,
        name="Peanut Butter",
        normalized_name="peanut butter",
        usda_fdc_id=1,
        usda_description="PB",
        basis="per_100g",
        serving_size=None,
        serving_size_unit=None,
        calories=100,
        protein_g=1.0,
        carbs_g=1.0,
        fat_g=1.0,
        now=now,
        aliases=["pb", "pbs"],
    )
    await session.commit()

    row = await repo.get_by_name(user_key=user_key, normalized_name="pb")
    assert row is not None
    assert sorted(row["aliases"]) == ["pb", "pbs"]


@pytest.mark.asyncio
async def test_remember_food_upsert_preserves_existing_aliases_when_not_provided(session: AsyncSession) -> None:
    """A subsequent ``upsert_usda`` with ``aliases=None`` preserves the existing aliases array."""
    user_key = f"user-{uuid.uuid4()}"
    now = DateTimeValue.now(tz=TimezoneValue.utc)
    repo = FoodMemoryRepository(session)
    await repo.upsert_usda(
        user_key=user_key, name="PB", normalized_name="peanut butter",
        usda_fdc_id=1, usda_description="PB", basis="per_100g",
        serving_size=None, serving_size_unit=None,
        calories=100, protein_g=1.0, carbs_g=1.0, fat_g=1.0,
        now=now, aliases=["pb"],
    )
    await session.commit()
    # Second upsert without aliases — should NOT clobber existing aliases.
    await repo.upsert_usda(
        user_key=user_key, name="PB", normalized_name="peanut butter",
        usda_fdc_id=1, usda_description="PB", basis="per_100g",
        serving_size=None, serving_size_unit=None,
        calories=200, protein_g=2.0, carbs_g=2.0, fat_g=2.0,
        now=now, aliases=None,
    )
    await session.commit()
    row = await repo.get_by_name(user_key=user_key, normalized_name="peanut butter")
    assert list(row["aliases"]) == ["pb"]
