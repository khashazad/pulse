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

from diet_tracker_server.db import to_sqlalchemy_url

pytestmark = pytest.mark.integration


def _integration_database_url() -> str:
    raw_url = os.getenv("TEST_DATABASE_URL")
    if raw_url is None:
        pytest.skip("Set TEST_DATABASE_URL to run integration tests")
    return to_sqlalchemy_url(raw_url)


async def _truncate(engine) -> None:
    async with engine.begin() as conn:
        await conn.exec_driver_sql(
            "TRUNCATE TABLE food_entries, meal_items, meals, food_memory, custom_foods, daily_logs, daily_target_profile RESTART IDENTITY CASCADE"
        )


@pytest_asyncio.fixture(scope="session")
async def session_factory():
    engine = create_async_engine(_integration_database_url(), pool_pre_ping=True)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()


@pytest_asyncio.fixture(autouse=True)
async def clean_database(session_factory):
    await _truncate(session_factory.kw["bind"])
    yield
    await _truncate(session_factory.kw["bind"])


@pytest_asyncio.fixture
async def session(session_factory):
    async with session_factory() as s:
        yield s


@pytest.mark.asyncio
async def test_food_memory_has_aliases_column(session: AsyncSession) -> None:
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


from diet_tracker_server.repositories.food_memory import FoodMemoryRepository
from diet_tracker_server.repositories.meals import MealsRepository


@pytest.mark.asyncio
async def test_food_memory_get_by_name_matches_alias(session: AsyncSession) -> None:
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
