"""Unit tests for `EntriesRepository` safety-sensitive write queries."""

from __future__ import annotations

import uuid
from unittest.mock import AsyncMock, Mock

import pytest

from pulse_server.repositories.entries import EntriesRepository


@pytest.mark.asyncio
async def test_delete_entry_requires_user_scope() -> None:
    """Deleting a food entry requires the caller's user key in the SQL predicate."""
    result = Mock()
    result.scalar_one_or_none.return_value = uuid.uuid4()
    session = Mock()
    session.execute = AsyncMock(return_value=result)
    repo = EntriesRepository(session)

    await repo.delete_entry(uuid.uuid4(), user_key="khash")

    stmt = session.execute.await_args.args[0]
    compiled = str(stmt.compile(compile_kwargs={"literal_binds": False}))
    assert "food_entries.id" in compiled
    assert "food_entries.user_key" in compiled
