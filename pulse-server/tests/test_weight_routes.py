"""HTTP tests for `/weight` and `/weight/{date}` endpoints.

Covers PUT (lb and kg units, future-date rejection, zero-weight 422),
GET single-day (200 and 404), list-range (happy plus inverted/oversize
400s), and DELETE (204 and 404). Uses a TestClient with DB and auth
middleware mocked.
"""

from __future__ import annotations

import os
import uuid
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from datetime import timedelta as TimeDeltaValue
from datetime import timezone as TimezoneValue
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("DATABASE_URL", "postgresql://localhost/test")
os.environ.setdefault("USDA_API_KEY", "test")


def _now() -> DateTimeValue:
    """Return the current UTC timestamp.

    **Outputs:**
    - datetime: Aware ``datetime`` in UTC.
    """
    return DateTimeValue.now(tz=TimezoneValue.utc)


def _row(log_date: DateValue, weight_lb: Decimal = Decimal("180.50")) -> dict:
    """Build a fake `weight_entries` row dict for repository return values.

    **Inputs:**
    - log_date (date): The row's ``log_date``.
    - weight_lb (Decimal): Weight in pounds (default ``180.50``).

    **Outputs:**
    - dict: Column→value mapping mirroring the ``weight_entries`` table shape.
    """
    return {
        "id": uuid.uuid4(),
        "user_key": "khash",
        "log_date": log_date,
        "weight_lb": weight_lb,
        "source_unit": "lb",
        "created_at": _now(),
        "updated_at": _now(),
    }


@pytest.fixture
def client() -> TestClient:
    """TestClient with DB pool, USDA client, and auth middleware mocked.

    **Outputs:**
    - TestClient: Client whose Bearer-authenticated requests pass auth.
    """
    fut = _now() + TimeDeltaValue(days=7)
    session_repo = AsyncMock()
    session_repo.get.return_value = {"email": "khashzd@gmail.com", "expires_at": fut}
    session_repo.slide.return_value = 1
    session_repo.delete.return_value = 1
    fake_db_session = AsyncMock()
    db_ctx = AsyncMock()
    db_ctx.__aenter__.return_value = fake_db_session
    db_ctx.__aexit__.return_value = None

    with patch("pulse_server.db.init_pool", new_callable=AsyncMock), patch(
        "pulse_server.db.bootstrap_schema", new_callable=AsyncMock
    ), patch("pulse_server.db.close_pool", new_callable=AsyncMock), patch(
        "pulse_server.usda.USDAClient"
    ) as mock_usda_client, patch(
        "pulse_server.auth.middleware.get_session", return_value=db_ctx
    ), patch(
        "pulse_server.auth.middleware.SessionsRepository", return_value=session_repo
    ):
        mock_usda_client.return_value.close = AsyncMock()
        from pulse_server.app import app
        from pulse_server.db import get_session_dependency

        async def _fake_session_dep():
            """Yield a `MagicMock` DB session with a working async `begin()` ctx."""
            session = MagicMock()
            session.begin = MagicMock()
            session.begin.return_value.__aenter__ = AsyncMock(return_value=session)
            session.begin.return_value.__aexit__ = AsyncMock(return_value=False)
            yield session

        app.dependency_overrides[get_session_dependency] = _fake_session_dep
        try:
            with TestClient(app) as test_client:
                yield test_client
        finally:
            app.dependency_overrides.pop(get_session_dependency, None)


HEADERS = {"Authorization": "Bearer tok"}


def test_unauthenticated_rejected(client: TestClient) -> None:
    """`GET /weight` without a Bearer token returns 401."""
    assert client.get("/weight?from=2025-01-01&to=2025-01-02").status_code == 401


def test_put_weight_lb(client: TestClient) -> None:
    """`PUT /weight/{date}` with `lb` payload returns the upserted row."""
    log_date = DateValue.today()
    row = _row(log_date)
    with patch(
        "pulse_server.routers.weight.upsert_weight",
        new_callable=AsyncMock,
    ) as upsert:
        from pulse_server.models.weight import WeightEntryResponse
        upsert.return_value = WeightEntryResponse(**row)
        resp = client.put(
            f"/weight/{log_date.isoformat()}",
            headers=HEADERS,
            json={"weight": "180.5", "unit": "lb"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["weight_lb"] == 180.50
    assert body["source_unit"] == "lb"


def test_put_weight_kg(client: TestClient) -> None:
    """`PUT /weight/{date}` with `kg` payload normalizes to `lb` in the response."""
    log_date = DateValue.today()
    row = _row(log_date, weight_lb=Decimal("154.32"))
    row["source_unit"] = "kg"
    with patch(
        "pulse_server.routers.weight.upsert_weight",
        new_callable=AsyncMock,
    ) as upsert:
        from pulse_server.models.weight import WeightEntryResponse
        upsert.return_value = WeightEntryResponse(**row)
        resp = client.put(
            f"/weight/{log_date.isoformat()}",
            headers=HEADERS,
            json={"weight": "70", "unit": "kg"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["weight_lb"] == 154.32
    assert body["source_unit"] == "kg"


def test_put_rejects_zero_weight(client: TestClient) -> None:
    """`PUT /weight/{date}` with zero weight returns 422 via request validation."""
    resp = client.put(
        f"/weight/{DateValue.today().isoformat()}",
        headers=HEADERS,
        json={"weight": "0", "unit": "lb"},
    )
    assert resp.status_code == 422


def test_put_rejects_future_date(client: TestClient) -> None:
    """`PUT /weight/{date}` with a future date returns 400."""
    future = (DateValue.today() + TimeDeltaValue(days=1)).isoformat()
    resp = client.put(
        f"/weight/{future}",
        headers=HEADERS,
        json={"weight": "180", "unit": "lb"},
    )
    assert resp.status_code == 400


def test_get_weight_404(client: TestClient) -> None:
    """`GET /weight/{date}` returns 404 when no entry exists."""
    with patch(
        "pulse_server.routers.weight.get_weight",
        new_callable=AsyncMock,
    ) as g:
        g.return_value = None
        resp = client.get(f"/weight/{DateValue.today().isoformat()}", headers=HEADERS)
    assert resp.status_code == 404


def test_get_weight_200(client: TestClient) -> None:
    """`GET /weight/{date}` returns 200 when the service yields a row."""
    row = _row(DateValue.today())
    with patch(
        "pulse_server.routers.weight.get_weight",
        new_callable=AsyncMock,
    ) as g:
        from pulse_server.models.weight import WeightEntryResponse
        g.return_value = WeightEntryResponse(**row)
        resp = client.get(f"/weight/{DateValue.today().isoformat()}", headers=HEADERS)
    assert resp.status_code == 200


def test_list_range(client: TestClient) -> None:
    """`GET /weight?from=&to=` returns the list of rows from the service."""
    today = DateValue.today()
    rows = [_row(today - TimeDeltaValue(days=2)), _row(today - TimeDeltaValue(days=1))]
    with patch(
        "pulse_server.routers.weight.list_weight_range",
        new_callable=AsyncMock,
    ) as lst:
        from pulse_server.models.weight import WeightEntryResponse
        lst.return_value = [WeightEntryResponse(**r) for r in rows]
        resp = client.get(
            f"/weight?from={(today - TimeDeltaValue(days=7)).isoformat()}&to={today.isoformat()}",
            headers=HEADERS,
        )
    assert resp.status_code == 200
    assert len(resp.json()) == 2


def test_list_range_rejects_inverted(client: TestClient) -> None:
    """`from` > `to` returns 400."""
    resp = client.get("/weight?from=2025-02-01&to=2025-01-01", headers=HEADERS)
    assert resp.status_code == 400


def test_list_range_rejects_oversize(client: TestClient) -> None:
    """Ranges wider than the allowed window return 400."""
    resp = client.get("/weight?from=2024-01-01&to=2025-12-31", headers=HEADERS)
    assert resp.status_code == 400


def test_delete_204(client: TestClient) -> None:
    """`DELETE /weight/{date}` returns 204 on success."""
    with patch(
        "pulse_server.routers.weight.delete_weight",
        new_callable=AsyncMock,
    ) as d:
        d.return_value = True
        resp = client.delete(f"/weight/{DateValue.today().isoformat()}", headers=HEADERS)
    assert resp.status_code == 204


def test_delete_404(client: TestClient) -> None:
    """`DELETE /weight/{date}` returns 404 when no row was deleted."""
    with patch(
        "pulse_server.routers.weight.delete_weight",
        new_callable=AsyncMock,
    ) as d:
        d.return_value = False
        resp = client.delete(f"/weight/{DateValue.today().isoformat()}", headers=HEADERS)
    assert resp.status_code == 404
