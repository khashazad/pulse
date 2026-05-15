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
    return DateTimeValue.now(tz=TimezoneValue.utc)


def _row(log_date: DateValue, weight_lb: Decimal = Decimal("180.50")) -> dict:
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
    fut = _now() + TimeDeltaValue(days=7)
    session_repo = AsyncMock()
    session_repo.get.return_value = {"email": "khashzd@gmail.com", "expires_at": fut}
    session_repo.slide.return_value = 1
    session_repo.delete.return_value = 1
    fake_db_session = AsyncMock()
    db_ctx = AsyncMock()
    db_ctx.__aenter__.return_value = fake_db_session
    db_ctx.__aexit__.return_value = None

    with patch("diet_tracker_server.db.init_pool", new_callable=AsyncMock), patch(
        "diet_tracker_server.db.bootstrap_schema", new_callable=AsyncMock
    ), patch("diet_tracker_server.db.close_pool", new_callable=AsyncMock), patch(
        "diet_tracker_server.usda.USDAClient"
    ) as mock_usda_client, patch(
        "diet_tracker_server.auth.middleware.get_session", return_value=db_ctx
    ), patch(
        "diet_tracker_server.auth.middleware.SessionsRepository", return_value=session_repo
    ):
        mock_usda_client.return_value.close = AsyncMock()
        from diet_tracker_server.app import app
        from diet_tracker_server.db import get_session_dependency

        async def _fake_session_dep():
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
    assert client.get("/weight?from=2025-01-01&to=2025-01-02").status_code == 401


def test_put_weight_lb(client: TestClient) -> None:
    log_date = DateValue.today()
    row = _row(log_date)
    with patch(
        "diet_tracker_server.routers.weight.upsert_weight",
        new_callable=AsyncMock,
    ) as upsert:
        from diet_tracker_server.models.weight import WeightEntryResponse
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
    log_date = DateValue.today()
    row = _row(log_date, weight_lb=Decimal("154.32"))
    row["source_unit"] = "kg"
    with patch(
        "diet_tracker_server.routers.weight.upsert_weight",
        new_callable=AsyncMock,
    ) as upsert:
        from diet_tracker_server.models.weight import WeightEntryResponse
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
    resp = client.put(
        f"/weight/{DateValue.today().isoformat()}",
        headers=HEADERS,
        json={"weight": "0", "unit": "lb"},
    )
    assert resp.status_code == 422


def test_put_rejects_future_date(client: TestClient) -> None:
    future = (DateValue.today() + TimeDeltaValue(days=1)).isoformat()
    resp = client.put(
        f"/weight/{future}",
        headers=HEADERS,
        json={"weight": "180", "unit": "lb"},
    )
    assert resp.status_code == 400


def test_get_weight_404(client: TestClient) -> None:
    with patch(
        "diet_tracker_server.routers.weight.get_weight",
        new_callable=AsyncMock,
    ) as g:
        g.return_value = None
        resp = client.get(f"/weight/{DateValue.today().isoformat()}", headers=HEADERS)
    assert resp.status_code == 404


def test_get_weight_200(client: TestClient) -> None:
    row = _row(DateValue.today())
    with patch(
        "diet_tracker_server.routers.weight.get_weight",
        new_callable=AsyncMock,
    ) as g:
        from diet_tracker_server.models.weight import WeightEntryResponse
        g.return_value = WeightEntryResponse(**row)
        resp = client.get(f"/weight/{DateValue.today().isoformat()}", headers=HEADERS)
    assert resp.status_code == 200


def test_list_range(client: TestClient) -> None:
    today = DateValue.today()
    rows = [_row(today - TimeDeltaValue(days=2)), _row(today - TimeDeltaValue(days=1))]
    with patch(
        "diet_tracker_server.routers.weight.list_weight_range",
        new_callable=AsyncMock,
    ) as lst:
        from diet_tracker_server.models.weight import WeightEntryResponse
        lst.return_value = [WeightEntryResponse(**r) for r in rows]
        resp = client.get(
            f"/weight?from={(today - TimeDeltaValue(days=7)).isoformat()}&to={today.isoformat()}",
            headers=HEADERS,
        )
    assert resp.status_code == 200
    assert len(resp.json()) == 2


def test_list_range_rejects_inverted(client: TestClient) -> None:
    resp = client.get("/weight?from=2025-02-01&to=2025-01-01", headers=HEADERS)
    assert resp.status_code == 400


def test_list_range_rejects_oversize(client: TestClient) -> None:
    resp = client.get("/weight?from=2024-01-01&to=2025-12-31", headers=HEADERS)
    assert resp.status_code == 400


def test_delete_204(client: TestClient) -> None:
    with patch(
        "diet_tracker_server.routers.weight.delete_weight",
        new_callable=AsyncMock,
    ) as d:
        d.return_value = True
        resp = client.delete(f"/weight/{DateValue.today().isoformat()}", headers=HEADERS)
    assert resp.status_code == 204


def test_delete_404(client: TestClient) -> None:
    with patch(
        "diet_tracker_server.routers.weight.delete_weight",
        new_callable=AsyncMock,
    ) as d:
        d.return_value = False
        resp = client.delete(f"/weight/{DateValue.today().isoformat()}", headers=HEADERS)
    assert resp.status_code == 404
