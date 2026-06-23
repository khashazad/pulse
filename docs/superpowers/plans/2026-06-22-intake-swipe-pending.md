# Intake Row Swipe Actions + Pending Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user swipe an Intake day-view food row to Delete (with 10s undo) or Make Pending (excluded from totals), and surface pending items behind a top count pill that expands to Approve/Delete each.

**Architecture:** Reuse the existing `confirmed` boolean that already drives prep-pending state end-to-end. Add the server inverse of confirm (`POST /entries/unconfirm`), mirror it on the iOS client + view-model, build a custom `SwipeActionsRow` (the day view is a `ScrollView` of bespoke cards, not a `List`, so `.swipeActions` is unavailable), and replace the always-visible pending section with a count pill + expandable panel. Delete is deferred 10s for undo (the server delete is hard, so undo cancels before the request fires).

**Tech Stack:** Server — FastAPI, SQLAlchemy Core (async psycopg3), Pydantic, pytest. iOS — SwiftUI (iOS 17+), `@Observable`, `actor PulseClient`, XCTest + `StubURLProtocol`.

## Global Constraints

- Server DTOs are `snake_case` Pydantic; iOS DTOs are camelCase Codable with explicit `CodingKeys` mapping `snake_case` JSON. A wire change touches both sides.
- iOS sends only `Authorization: Bearer <token>`; never `?user_key=` / `X-API-Key`.
- iOS styling goes through `Theme.CTP.*` / `Theme.BG.*` / `Theme.FG.*` and `.ctpCard()` — no raw `Color` literals or system grays.
- Every method/function gets a doc-comment block above its signature (docstring for Python, `///` for Swift) covering purpose, params, returns, and raises.
- Server: `schema.sql` is the single source of truth for schema — but **this feature adds no schema changes** (`food_entries.confirmed` already exists).
- iOS Xcode project is generated: run `source .envrc && xcodegen generate` from `ios/` before building if `project.yml` or new files require it (new files under existing groups are picked up by regeneration).
- Commit after each task.

---

## File Structure

**Server (`server/src/pulse_server/`):**
- Modify `repositories/entries.py` — add `unconfirm_entries` repo method (inverse of `confirm_entries`).
- Modify `services/entries_service.py` — add `unconfirm_entries` service (inverse of `confirm_pending_entries`).
- Modify `models/entries.py` — add `EntriesPendingRequest` / `EntriesPendingResponse`.
- Modify `models/__init__.py` — export the two new models.
- Modify `routers/entries.py` — add `POST /entries/unconfirm` endpoint.
- Tests: `server/tests/integration/test_repositories.py`, `server/tests/test_entries_api.py`.

**iOS (`ios/Pulse/`):**
- Modify `Models/EntryModels.swift` — add `EntriesPendingRequest`.
- Modify `Networking/PulseClient+Food.swift` — add `makePending(ids:)`.
- Modify `State/DayMacroModel.swift` — add `PendingState` + `makePending`, and the deferred-delete buffer (`requestDelete` / `undoDelete` / `commitPendingDelete` / `flushPendingDelete` / `pendingDelete` + optimistic summary mutation).
- Create `Views/Components/SwipeActionsRow.swift` — custom swipe wrapper.
- Create `Views/Components/UndoSnackbar.swift` — the 10s undo overlay.
- Modify `Views/DayMacroView.swift` — swipe on confirmed rows, replace pending section with count pill + expandable panel, mount undo snackbar, flush on disappear.
- Tests: `ios/PulseTests/EntryWriteClientTests.swift`, new `ios/PulseTests/MakePendingTests.swift`, new `ios/PulseTests/DeferredDeleteTests.swift`.

---

## Task 1: Server — `unconfirm_entries` repository method

**Files:**
- Modify: `server/src/pulse_server/repositories/entries.py` (add method to `EntriesRepository`, after `confirm_entries` ~line 329)
- Test: `server/tests/integration/test_repositories.py`

**Interfaces:**
- Consumes: existing `_food_entry_response_columns()`, `food_entries` table, `update` from sqlalchemy.
- Produces: `EntriesRepository.unconfirm_entries(entry_ids: Sequence[UUID], user_key: str) -> list[dict[str, Any]]` — rows whose `confirmed` flipped `True → False`, idempotent and user-scoped.

- [ ] **Step 1: Write the failing test**

Add to `server/tests/integration/test_repositories.py` (mirror `test_confirm_entries_flips_scoped_and_idempotent` at line 423; reuse the same helpers/fixtures it uses to create a confirmed entry — match that test's setup for `entries_repo`, `user_key`, `other_user`, and entry creation):

```python
@pytest.mark.integration
async def test_unconfirm_entries_flips_scoped_and_idempotent(session: AsyncSession) -> None:
    """``unconfirm_entries`` flips confirmed→pending, is user-scoped, and is idempotent."""
    user_key = "khash"
    other_user = "intruder"
    entries_repo = EntriesRepository(session)
    log_date = DateValue(2026, 6, 22)
    log_id = canonical_daily_log_id(user_key, log_date)
    await entries_repo.ensure_daily_log(log_id, user_key, log_date)
    entry_id = uuid.uuid4()
    await entries_repo.create_food_entry(
        FoodEntryPayload(
            entry_id=entry_id, daily_log_id=log_id, user_key=user_key,
            entry_group_id=uuid.uuid4(), display_name="Bowl", quantity_text="1",
            normalized_quantity_value=None, normalized_quantity_unit=None,
            usda_fdc_id=1, usda_description="Bowl", custom_food_id=None,
            calories=600, protein_g=50, carbs_g=40, fat_g=20,
            consumed_at=DateTimeValue(2026, 6, 22, 12, 0), meal_id=None,
            meal_name=None, confirmed=True,
        )
    )

    # Another user cannot unconfirm it.
    assert await entries_repo.unconfirm_entries([entry_id], other_user) == []

    changed = await entries_repo.unconfirm_entries([entry_id], user_key)
    assert len(changed) == 1
    assert changed[0]["confirmed"] is False

    # Idempotent: already-pending rows are skipped.
    assert await entries_repo.unconfirm_entries([entry_id], user_key) == []
```

Ensure imports at the top of the test module include `uuid`, `DateValue`/`DateTimeValue`, `EntriesRepository`, `FoodEntryPayload`, `canonical_daily_log_id` (match what `test_confirm_entries_flips_scoped_and_idempotent` already imports — most are present).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_repositories.py::test_unconfirm_entries_flips_scoped_and_idempotent -v`
Expected: FAIL with `AttributeError: 'EntriesRepository' object has no attribute 'unconfirm_entries'`.

- [ ] **Step 3: Write minimal implementation**

Add to `EntriesRepository` in `server/src/pulse_server/repositories/entries.py`, directly after `confirm_entries`:

```python
    async def unconfirm_entries(
        self, entry_ids: Sequence[UUID], user_key: str
    ) -> list[dict[str, Any]]:
        """Move confirmed food entries back to pending and return the updated rows.

        Flips ``confirmed`` from ``True`` to ``False`` for the given entry ids
        owned by ``user_key`` (the inverse of :meth:`confirm_entries`). Already-
        pending or non-matching ids are skipped, so the operation is idempotent
        and only rows actually changed are returned.

        **Inputs:**
        - entry_ids (Sequence[UUID]): Food-entry primary keys to make pending.
        - user_key (str): Owning user identifier used to scope the update.

        **Outputs:**
        - list[dict[str, Any]]: The rows moved to pending (response column
          projection); empty when no row matched or all were already pending.

        **Raises:**
        - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
        """
        if not entry_ids:
            return []
        stmt = (
            update(food_entries)
            .where(food_entries.c.id.in_(list(entry_ids)))
            .where(food_entries.c.user_key == user_key)
            .where(food_entries.c.confirmed.is_(True))
            .values(confirmed=False)
            .returning(*_food_entry_response_columns())
        )
        result = await self._session.execute(stmt)
        return [dict(row) for row in result.mappings().all()]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_repositories.py::test_unconfirm_entries_flips_scoped_and_idempotent -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/src/pulse_server/repositories/entries.py server/tests/integration/test_repositories.py
git commit -m "feat(server): add unconfirm_entries repository method"
```

---

## Task 2: Server — `unconfirm_entries` service

**Files:**
- Modify: `server/src/pulse_server/services/entries_service.py` (add after `confirm_pending_entries` ~line 201)
- Test: `server/tests/integration/test_repositories.py`

**Interfaces:**
- Consumes: `EntriesRepository.unconfirm_entries` (Task 1), `transaction`, `list_entries_by_daily_log_id`.
- Produces: `unconfirm_entries(session: AsyncSession, user_key: str, entry_ids: Sequence[UUID]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]` — `(changed_rows, day_rows)`; raises `ValueError` when changed rows span >1 daily log.

- [ ] **Step 1: Write the failing test**

Add to `server/tests/integration/test_repositories.py` (mirror `test_confirm_pending_entries_rejects_cross_day` at line 499 for setup — create two confirmed entries on two different dates for the same user, then call the service). Import the service at the top of the test module: `from pulse_server.services.entries_service import unconfirm_entries`.

```python
@pytest.mark.integration
async def test_unconfirm_entries_rejects_cross_day(session: AsyncSession) -> None:
    """``unconfirm_entries`` rejects ids spanning more than one day."""
    user_key = "khash"
    entries_repo = EntriesRepository(session)
    ids: list[uuid.UUID] = []
    for day in (DateValue(2026, 6, 21), DateValue(2026, 6, 22)):
        log_id = canonical_daily_log_id(user_key, day)
        await entries_repo.ensure_daily_log(log_id, user_key, day)
        entry_id = uuid.uuid4()
        ids.append(entry_id)
        await entries_repo.create_food_entry(
            FoodEntryPayload(
                entry_id=entry_id, daily_log_id=log_id, user_key=user_key,
                entry_group_id=uuid.uuid4(), display_name="Bowl", quantity_text="1",
                normalized_quantity_value=None, normalized_quantity_unit=None,
                usda_fdc_id=1, usda_description="Bowl", custom_food_id=None,
                calories=100, protein_g=1, carbs_g=1, fat_g=1,
                consumed_at=DateTimeValue(day.year, day.month, day.day, 12, 0),
                meal_id=None, meal_name=None, confirmed=True,
            )
        )

    with pytest.raises(ValueError):
        await unconfirm_entries(session=session, user_key=user_key, entry_ids=ids)


@pytest.mark.integration
async def test_unconfirm_entries_returns_changed_and_day_rows(session: AsyncSession) -> None:
    """``unconfirm_entries`` returns the changed rows plus the day's full rows."""
    user_key = "khash"
    entries_repo = EntriesRepository(session)
    day = DateValue(2026, 6, 22)
    log_id = canonical_daily_log_id(user_key, day)
    await entries_repo.ensure_daily_log(log_id, user_key, day)
    keep_id, flip_id = uuid.uuid4(), uuid.uuid4()
    for entry_id, kcal in ((keep_id, 300), (flip_id, 700)):
        await entries_repo.create_food_entry(
            FoodEntryPayload(
                entry_id=entry_id, daily_log_id=log_id, user_key=user_key,
                entry_group_id=uuid.uuid4(), display_name="Bowl", quantity_text="1",
                normalized_quantity_value=None, normalized_quantity_unit=None,
                usda_fdc_id=1, usda_description="Bowl", custom_food_id=None,
                calories=kcal, protein_g=1, carbs_g=1, fat_g=1,
                consumed_at=DateTimeValue(2026, 6, 22, 12, 0),
                meal_id=None, meal_name=None, confirmed=True,
            )
        )

    changed, day_rows = await unconfirm_entries(
        session=session, user_key=user_key, entry_ids=[flip_id]
    )
    assert len(changed) == 1 and changed[0]["id"] == flip_id
    assert len(day_rows) == 2
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_repositories.py::test_unconfirm_entries_rejects_cross_day tests/integration/test_repositories.py::test_unconfirm_entries_returns_changed_and_day_rows -v`
Expected: FAIL with `ImportError: cannot import name 'unconfirm_entries'`.

- [ ] **Step 3: Write minimal implementation**

Add to `server/src/pulse_server/services/entries_service.py` after `confirm_pending_entries`:

```python
async def unconfirm_entries(
    session: AsyncSession,
    user_key: str,
    entry_ids: Sequence[UUID],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Move confirmed entries back to pending and return them plus their day's rows.

    The inverse of :func:`confirm_pending_entries`. Flips ``confirmed`` to
    ``False`` for the owned, currently-confirmed ids inside a transaction, then
    re-reads every entry on the affected daily log so the caller can recompute
    that day's confirmed totals. Already-pending or non-matching ids are silently
    skipped (idempotent).

    **Inputs:**
    - session (AsyncSession): Active SQLAlchemy session used for the transaction.
    - user_key (str): User identifier owning the entries.
    - entry_ids (Sequence[UUID]): Food-entry ids to make pending.

    **Outputs:**
    - tuple[list[dict[str, Any]], list[dict[str, Any]]]: ``(changed_rows,
      day_rows)`` — the rows actually moved to pending, and all entries on the
      affected daily log for recomputing the day's confirmed total.

    **Raises:**
    - ValueError: Raised when the changed entries span more than one daily log;
      the single ``daily_totals`` field in the response can only represent one
      day, so a cross-day request is rejected (and rolled back).
    - sqlalchemy.exc.SQLAlchemyError: Raised when any SQL operation fails; the
      transaction is rolled back.
    """
    entries_repo = EntriesRepository(session)
    async with transaction(session):
        changed_rows = await entries_repo.unconfirm_entries(entry_ids, user_key)
        affected_logs = {row["daily_log_id"] for row in changed_rows}
        if len(affected_logs) > 1:
            raise ValueError("Pending ids must all belong to the same day")
        day_rows: list[dict[str, Any]] = []
        for log_id in affected_logs:
            day_rows.extend(await entries_repo.list_entries_by_daily_log_id(str(log_id)))
    return changed_rows, day_rows
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && TEST_DATABASE_URL=postgresql://localhost/test uv run pytest tests/integration/test_repositories.py -k unconfirm -v`
Expected: PASS (all three unconfirm tests).

- [ ] **Step 5: Commit**

```bash
git add server/src/pulse_server/services/entries_service.py server/tests/integration/test_repositories.py
git commit -m "feat(server): add unconfirm_entries service with cross-day guard"
```

---

## Task 3: Server — `POST /entries/unconfirm` endpoint + models

**Files:**
- Modify: `server/src/pulse_server/models/entries.py` (add after `EntriesConfirmResponse` ~line 137)
- Modify: `server/src/pulse_server/models/__init__.py` (import + `__all__`, near the `EntriesConfirm*` entries)
- Modify: `server/src/pulse_server/routers/entries.py` (imports + new endpoint after `confirm_entries` ~line 132)
- Test: `server/tests/test_entries_api.py`

**Interfaces:**
- Consumes: `unconfirm_entries` service (Task 2), `EntriesPendingRequest`/`EntriesPendingResponse`, existing `confirmed_entries`, `sum_food_entry_macros`, `FoodEntryResponse`.
- Produces: HTTP `POST /entries/unconfirm` accepting `{"ids": [uuid, ...]}` (≥1), returning `{"entries": [...], "daily_totals": {...}}`; 422 on cross-day.

- [ ] **Step 1: Write the failing test**

Add to `server/tests/test_entries_api.py` (mirror `test_confirm_entries_200` / `_requires_ids` / `_cross_day_returns_422`; reuse the same `_entry_row` helper, `AUTH_HEADERS`, and `rest_client` fixture already in that file):

```python
def test_unconfirm_entries_200(rest_client: TestClient) -> None:
    """`POST /entries/unconfirm` returns the changed entries plus the refreshed day total."""
    changed = [_entry_row(700, confirmed=False)]
    day_rows = [_entry_row(300, confirmed=True), _entry_row(700, confirmed=False)]
    with patch(
        "pulse_server.routers.entries.unconfirm_entries",
        new_callable=AsyncMock,
    ) as svc:
        svc.return_value = (changed, day_rows)
        resp = rest_client.post(
            "/entries/unconfirm",
            headers=AUTH_HEADERS,
            json={"ids": [str(uuid.uuid4())]},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["entries"]) == 1
    # Only the 300-kcal row is still confirmed, so the day total excludes the flipped one.
    assert body["daily_totals"]["calories"] == 300


def test_unconfirm_entries_requires_ids(rest_client: TestClient) -> None:
    """`POST /entries/unconfirm` rejects an empty id list with 422."""
    resp = rest_client.post("/entries/unconfirm", headers=AUTH_HEADERS, json={"ids": []})
    assert resp.status_code == 422


def test_unconfirm_entries_cross_day_returns_422(rest_client: TestClient) -> None:
    """A cross-day request (service raises `ValueError`) surfaces as 422."""
    with patch(
        "pulse_server.routers.entries.unconfirm_entries",
        new_callable=AsyncMock,
    ) as svc:
        svc.side_effect = ValueError("Pending ids must all belong to the same day")
        resp = rest_client.post(
            "/entries/unconfirm",
            headers=AUTH_HEADERS,
            json={"ids": [str(uuid.uuid4()), str(uuid.uuid4())]},
        )
    assert resp.status_code == 422
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && uv run pytest tests/test_entries_api.py -k unconfirm -v`
Expected: FAIL — `test_unconfirm_entries_200` returns 404 (route not registered); the patch target `pulse_server.routers.entries.unconfirm_entries` does not yet exist.

- [ ] **Step 3a: Add the models**

In `server/src/pulse_server/models/entries.py` after `EntriesConfirmResponse`:

```python
class EntriesPendingRequest(BaseModel):
    """Request body for ``POST /entries/unconfirm`` — the ids to move back to pending.

    Sent for a single-entry "make pending" (one id) or several at once. At least
    one id is required.
    """

    ids: list[UUID] = Field(min_length=1)


class EntriesPendingResponse(BaseModel):
    """Response body for ``POST /entries/unconfirm`` — changed rows plus the day total.

    ``daily_totals`` is the affected day's confirmed total recomputed after the
    change, so the client can update the day view without a second request.
    """

    entries: list[FoodEntryResponse]
    daily_totals: MacroTotals
```

In `server/src/pulse_server/models/__init__.py`, add `EntriesPendingRequest` and `EntriesPendingResponse` to both the `from .entries import (...)` block and `__all__` (alongside the `EntriesConfirm*` lines).

- [ ] **Step 3b: Add the endpoint**

In `server/src/pulse_server/routers/entries.py`:

Extend the models import (the `from pulse_server.models import (...)` block) with `EntriesPendingRequest` and `EntriesPendingResponse`.

Extend the service import to:

```python
from pulse_server.services.entries_service import (
    confirm_pending_entries,
    create_entries_with_side_effects,
    unconfirm_entries,
)
```

Add the endpoint after `confirm_entries` (note: the function name is `make_entries_pending` to avoid shadowing the imported `unconfirm_entries` service):

```python
@router.post("/entries/unconfirm", response_model=EntriesPendingResponse)
async def make_entries_pending(
    request: Request,
    body: EntriesPendingRequest,
    session: AsyncSession = Depends(get_session_dependency),
) -> EntriesPendingResponse:
    """Move confirmed food entries back to pending so they stop counting toward totals.

    The inverse of ``POST /entries/confirm``. Used by the iOS day view's swipe
    "Make Pending" action. Idempotent — ids that are already pending or not owned
    by the user are ignored.

    **Inputs:**
    - request (Request): Active request providing ``user_key``.
    - body (EntriesPendingRequest): The entry ids to make pending (at least one).
    - session (AsyncSession): DB session dependency.

    **Outputs:**
    - EntriesPendingResponse: The newly pending entries plus the affected day's
      recomputed confirmed totals.

    **Exceptions:**
    - HTTPException(422): Raised when the ids span more than one day (the single
      ``daily_totals`` field can only represent one day).
    - RuntimeError: Raised when the database pool is not initialized.
    - sqlalchemy.exc.SQLAlchemyError: Raised when SQL execution fails.
    """
    try:
        changed_rows, day_rows = await unconfirm_entries(
            session=session,
            user_key=request.state.user_key,
            entry_ids=body.ids,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    changed = [FoodEntryResponse(**row) for row in changed_rows]
    day_entries = [FoodEntryResponse(**row) for row in day_rows]
    return EntriesPendingResponse(
        entries=changed,
        daily_totals=sum_food_entry_macros(confirmed_entries(day_entries)),
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && uv run pytest tests/test_entries_api.py -k unconfirm -v && uv run pytest tests/ -q`
Expected: the three unconfirm tests PASS; full suite stays green (incl. `test_config` and any `__all__` export checks).

- [ ] **Step 5: Commit**

```bash
git add server/src/pulse_server/models/entries.py server/src/pulse_server/models/__init__.py server/src/pulse_server/routers/entries.py server/tests/test_entries_api.py
git commit -m "feat(server): add POST /entries/unconfirm endpoint"
```

---

## Task 4: iOS — `EntriesPendingRequest` + `PulseClient.makePending`

**Files:**
- Modify: `ios/Pulse/Models/EntryModels.swift` (add after `EntriesConfirmRequest` ~line 207)
- Modify: `ios/Pulse/Networking/PulseClient+Food.swift` (add after `confirmEntries` ~line 115)
- Test: `ios/PulseTests/EntryWriteClientTests.swift`

**Interfaces:**
- Consumes: `EntryWriteResponse`, `http.makeURL`, `sendJSON`, `JSONEncoder.pulseDefault()`.
- Produces: `struct EntriesPendingRequest: Encodable, Equatable { let ids: [UUID] }`; `PulseClient.makePending(ids: [UUID]) async throws -> EntryWriteResponse` hitting `POST /entries/unconfirm`.

- [ ] **Step 1: Write the failing test**

Add to `ios/PulseTests/EntryWriteClientTests.swift` (mirror `test_confirmEntries_postsIdsAndDecodes` at line 155; reuse its `fixture("entries_create")`, `makeClient`, `bodyObject` helpers):

```swift
    func test_makePending_postsIdsAndDecodes() async throws {
        let json = try fixture("entries_create")
        var captured: URLRequest?
        let (client, stub) = makeClient { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let id1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let id2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let resp = try await client.makePending(ids: [id1, id2])

        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/entries/unconfirm")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
        let obj = try bodyObject(stub)
        let ids = try XCTUnwrap(obj["ids"] as? [String])
        XCTAssertEqual(ids.map { $0.uppercased() }, [id1.uuidString, id2.uuidString])
        XCTAssertEqual(resp.entries.count, 1)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild -project Pulse.xcodeproj -scheme Pulse -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:PulseTests/EntryWriteClientTests/test_makePending_postsIdsAndDecodes 2>&1 | tail -30`
Expected: FAIL to compile — `value of type 'PulseClient' has no member 'makePending'`.

- [ ] **Step 3a: Add the request model**

In `ios/Pulse/Models/EntryModels.swift` after `EntriesConfirmRequest`:

```swift
/// Request body for `POST /entries/unconfirm` — the confirmed entry ids to move
/// back to pending (excluded from the day's totals). Mirrors
/// `EntriesConfirmRequest`; the server response reuses `EntryWriteResponse`
/// (the changed entries plus the affected day's recomputed totals).
struct EntriesPendingRequest: Encodable, Equatable {
    let ids: [UUID]
}
```

- [ ] **Step 3b: Add the client method**

In `ios/Pulse/Networking/PulseClient+Food.swift` after `confirmEntries(ids:)`:

```swift
    /// Moves one or more confirmed food entries back to pending (`POST
    /// /entries/unconfirm`). The inverse of `confirmEntries`: pending entries are
    /// excluded from the day's totals until confirmed again. Idempotent on the
    /// server.
    /// Inputs:
    ///   - ids: the confirmed `FoodEntry` UUIDs to make pending (at least one).
    /// Outputs: an `EntryWriteResponse` with the changed entries and the
    /// affected day's recomputed (confirmed-only) macro totals.
    /// Exceptions: `PulseError` on transport, status, or decoding failure.
    func makePending(ids: [UUID]) async throws -> EntryWriteResponse {
        let url = try http.makeURL(path: "/entries/unconfirm", query: [])
        let body = try JSONEncoder.pulseDefault().encode(EntriesPendingRequest(ids: ids))
        return try await sendJSON(url: url, method: "POST", body: body)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios && xcodebuild -project Pulse.xcodeproj -scheme Pulse -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:PulseTests/EntryWriteClientTests/test_makePending_postsIdsAndDecodes 2>&1 | tail -20`
Expected: PASS (`** TEST SUCCEEDED **`).

- [ ] **Step 5: Commit**

```bash
git add ios/Pulse/Models/EntryModels.swift ios/Pulse/Networking/PulseClient+Food.swift ios/PulseTests/EntryWriteClientTests.swift
git commit -m "feat(ios): add makePending client call for POST /entries/unconfirm"
```

---

## Task 5: iOS — `DayMacroModel.makePending` + `PendingState`

**Files:**
- Modify: `ios/Pulse/State/DayMacroModel.swift` (add enum near `ConfirmState` ~line 60; property near `confirmState` ~line 19; methods near `confirmEntries` ~line 241)
- Test: Create `ios/PulseTests/MakePendingTests.swift`

**Interfaces:**
- Consumes: `auth.makeClient()`, `PulseClient.makePending(ids:)` (Task 4), `auth.handleUnauthorized()`, `load()`.
- Produces: `DayMacroModel.PendingState` (`idle | working | finished(count: Int) | failed(PulseError)`); `var pendingState: PendingState`; `func makePending(_ entries: [FoodEntry]) async`; `func resetPendingState()`.

- [ ] **Step 1: Write the failing test**

Create `ios/PulseTests/MakePendingTests.swift` (copy the scaffolding from `ConfirmEntriesTests.swift` — same `testService`/`testAccount`/`activeStubs`, `tearDown`, `entry`, `signedInAuth`, `signedOutAuth`, `http` helpers; only the assertions differ):

```swift
// PulseTests/MakePendingTests.swift
import XCTest
@testable import Pulse

/// Unit tests for `DayMacroModel.makePending` — the action that moves confirmed
/// entries back to pending. Mirrors `ConfirmEntriesTests`: covers the
/// empty/guard, signed-out, server-error, and unauthorized branches. The success
/// path (one request + a day reload) is a straight composition of
/// `PulseClient.makePending` (covered by `EntryWriteClientTests`) and `load()`.
final class MakePendingTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private let testAccount = "make-pending-\(UUID().uuidString)"
    private var activeStubs: [StubURLProtocol.Registration] = []

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        _ = KeychainStore.delete(service: testService, account: testAccount)
        super.tearDown()
    }

    private func entry(id: UUID = UUID()) -> FoodEntry {
        FoodEntry(
            id: id, dailyLogId: UUID(), userKey: "khash", entryGroupId: UUID(),
            displayName: "Oats", quantityText: "80 g",
            normalizedQuantityValue: 80, normalizedQuantityUnit: "g",
            usdaFdcId: 1, usdaDescription: "Oats", customFoodId: nil,
            calories: 320, proteinG: 10, carbsG: 54, fatG: 6,
            mealId: nil, mealName: nil, consumedAt: .now, createdAt: .now,
            isConfirmed: true
        )
    }

    private func signedInAuth(responder: @escaping StubURLProtocol.Responder) -> AuthSession {
        let stub = StubURLProtocol.makeSession(responder: responder)
        activeStubs.append(stub)
        _ = KeychainStore.write(
            #"{"token":"tok","email":"khashzd@gmail.com"}"#,
            service: testService, account: testAccount
        )
        return AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService, keychainAccount: testAccount,
            urlSession: stub.session
        )
    }

    private func signedOutAuth() -> AuthSession {
        _ = KeychainStore.delete(service: testService, account: testAccount)
        return AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService, keychainAccount: testAccount
        )
    }

    private func http(_ req: URLRequest, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    func test_makePending_empty_finishesWithoutRequest() async {
        var called = false
        let auth = signedInAuth { req in
            called = true
            return (self.http(req, 200), Data())
        }
        let model = DayMacroModel(date: Date(), auth: auth)
        await model.makePending([])
        XCTAssertEqual(model.pendingState, .finished(count: 0))
        XCTAssertFalse(called, "an empty make-pending must not hit the network")
    }

    func test_makePending_notSignedIn_reportsFailure() async {
        let model = DayMacroModel(date: Date(), auth: signedOutAuth())
        await model.makePending([entry()])
        XCTAssertEqual(model.pendingState, .failed(.notSignedIn))
    }

    func test_makePending_serverError_reportsFailure() async {
        let auth = signedInAuth { req in (self.http(req, 500), Data()) }
        let model = DayMacroModel(date: Date(), auth: auth)
        await model.makePending([entry()])
        XCTAssertEqual(model.pendingState, .failed(.server(status: 500)))
    }

    func test_makePending_unauthorized_failsAndSignsOut() async {
        let auth = signedInAuth { req in (self.http(req, 401), Data()) }
        let model = DayMacroModel(date: Date(), auth: auth)
        await model.makePending([entry()])
        XCTAssertEqual(model.pendingState, .failed(.unauthorized))
        XCTAssertFalse(auth.isSignedIn, "401 must route through handleUnauthorized")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild -project Pulse.xcodeproj -scheme Pulse -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:PulseTests/MakePendingTests 2>&1 | tail -30`
Expected: FAIL to compile — `value of type 'DayMacroModel' has no member 'makePending'` / `pendingState`. (If the new file isn't picked up, run `source .envrc && xcodegen generate` first.)

- [ ] **Step 3a: Add the state enum + property**

In `ios/Pulse/State/DayMacroModel.swift`, add the property after `confirmState` (line 19):

```swift
    /// Outcome of the most recent "make pending" (unconfirm) action.
    private(set) var pendingState: PendingState = .idle
```

Add the enum after `ConfirmState` (after line 60):

```swift
    /// Discrete states of a make-pending (unconfirm) action — the inverse of
    /// confirm. One atomic `POST /entries/unconfirm` over all selected ids, so
    /// there is no partial-failure remainder to track.
    enum PendingState: Equatable {
        case idle
        case working
        case finished(count: Int)
        case failed(PulseError)
    }
```

- [ ] **Step 3b: Add the methods**

In `ios/Pulse/State/DayMacroModel.swift`, after `resetConfirmState()` (line 248):

```swift
    /// Moves the given confirmed entries back to pending in one atomic `POST
    /// /entries/unconfirm`, then reloads the day so the now-pending entries drop
    /// out of the totals. The inverse of `confirmEntries`. Routes a 401 through
    /// `AuthSession`. A no-op (empty input) finishes immediately without a
    /// request.
    /// - Parameters:
    ///   - entries: The confirmed entries to make pending.
    /// - Returns: Nothing; updates `pendingState` and, on success, reloads `state`.
    func makePending(_ entries: [FoodEntry]) async {
        guard let client = auth?.makeClient() else {
            pendingState = .failed(.notSignedIn)
            return
        }
        let ids = entries.map(\.id)
        guard !ids.isEmpty else {
            pendingState = .finished(count: 0)
            return
        }
        pendingState = .working
        do {
            let response = try await client.makePending(ids: ids)
            pendingState = .finished(count: response.entries.count)
            await load()
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            pendingState = .failed(error)
        } catch {
            pendingState = .failed(.server(status: -1))
        }
    }

    /// Resets the make-pending action back to idle so stale success/failure state
    /// doesn't leak across presentations.
    /// - Returns: Nothing.
    func resetPendingState() {
        pendingState = .idle
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios && source .envrc && xcodegen generate && xcodebuild -project Pulse.xcodeproj -scheme Pulse -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:PulseTests/MakePendingTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Pulse/State/DayMacroModel.swift ios/PulseTests/MakePendingTests.swift ios/project.yml
git commit -m "feat(ios): add DayMacroModel.makePending + PendingState"
```

---

## Task 6: iOS — deferred-delete buffer in `DayMacroModel`

**Files:**
- Modify: `ios/Pulse/State/DayMacroModel.swift` (add `undoWindow` to init; buffer state; helpers near the delete methods)
- Test: Create `ios/PulseTests/DeferredDeleteTests.swift`

**Interfaces:**
- Consumes: existing `deleteEntries(_:)`, `load()`, `state: LoadState<DailySummary>`, `DailySummary`, `MacroTotals`.
- Produces:
  - `struct DayMacroModel.BufferedDelete: Equatable { let entries: [FoodEntry] }`
  - `var pendingDelete: BufferedDelete?`
  - `init(date:auth:undoWindow:)` with `undoWindow: Duration = .seconds(10)`
  - `func requestDelete(_ entries: [FoodEntry])` — optimistically removes rows + adjusts totals, starts the undo window.
  - `func undoDelete()` — cancels + restores snapshot, no request.
  - `func commitPendingDelete() async` — fires the buffered `DELETE`s then reloads.
  - `func flushPendingDelete() async` — alias for `commitPendingDelete` (for `.onDisappear`/background).
  - `static func summary(_ summary: DailySummary, removing entries: [FoodEntry]) -> DailySummary`

- [ ] **Step 1: Write the failing test**

Create `ios/PulseTests/DeferredDeleteTests.swift`. These tests use a long `undoWindow` so the timer never fires mid-test, and drive commit deterministically via `flushPendingDelete()`. A signed-in `DayMacroModel` whose `state` is preloaded is needed; preload by stubbing the summary load. To keep it simple, the optimistic/undo tests assert on `state` and `pendingDelete` without any network, and the commit test counts `DELETE` calls.

```swift
// PulseTests/DeferredDeleteTests.swift
import XCTest
@testable import Pulse

/// Unit tests for `DayMacroModel`'s deferred-delete buffer: optimistic removal,
/// undo (no request), and commit (fires the buffered DELETEs). Uses a long undo
/// window so the auto-commit timer never fires mid-test; commit is driven
/// explicitly via `flushPendingDelete()`.
final class DeferredDeleteTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private let testAccount = "deferred-delete-\(UUID().uuidString)"
    private var activeStubs: [StubURLProtocol.Registration] = []

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        _ = KeychainStore.delete(service: testService, account: testAccount)
        super.tearDown()
    }

    private func entry(_ id: UUID, kcal: Int, confirmed: Bool = true) -> FoodEntry {
        FoodEntry(
            id: id, dailyLogId: UUID(), userKey: "khash", entryGroupId: UUID(),
            displayName: "Food", quantityText: "1",
            normalizedQuantityValue: nil, normalizedQuantityUnit: nil,
            usdaFdcId: 1, usdaDescription: "Food", customFoodId: nil,
            calories: kcal, proteinG: 1, carbsG: 1, fatG: 1,
            mealId: nil, mealName: nil, consumedAt: .now, createdAt: .now,
            isConfirmed: confirmed
        )
    }

    private func summary(_ entries: [FoodEntry], consumed: Int) -> DailySummary {
        DailySummary(
            date: Date(),
            target: MacroTargets(calories: 2000, proteinG: 150, carbsG: 200, fatG: 60, targetWeightLb: nil),
            consumed: MacroTotals(calories: consumed, proteinG: 0, carbsG: 0, fatG: 0),
            remaining: MacroTotals(calories: 2000 - consumed, proteinG: 0, carbsG: 0, fatG: 0),
            entries: entries
        )
    }

    private func signedInAuth(responder: @escaping StubURLProtocol.Responder) -> AuthSession {
        let stub = StubURLProtocol.makeSession(responder: responder)
        activeStubs.append(stub)
        _ = KeychainStore.write(
            #"{"token":"tok","email":"khashzd@gmail.com"}"#,
            service: testService, account: testAccount
        )
        return AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService, keychainAccount: testAccount,
            urlSession: stub.session
        )
    }

    private func http(_ req: URLRequest, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    /// `summary(_:removing:)` drops the rows and subtracts only confirmed macros.
    func test_summaryRemoving_subtractsOnlyConfirmedMacros() {
        let a = entry(UUID(), kcal: 300, confirmed: true)
        let b = entry(UUID(), kcal: 700, confirmed: false) // pending: not in consumed
        let s = summary([a, b], consumed: 300)

        let afterA = DayMacroModel.summary(s, removing: [a])
        XCTAssertEqual(afterA.entries.map(\.id), [b.id])
        XCTAssertEqual(afterA.consumed.calories, 0)
        XCTAssertEqual(afterA.remaining.calories, 2000)

        let afterB = DayMacroModel.summary(s, removing: [b])
        XCTAssertEqual(afterB.entries.map(\.id), [a.id])
        XCTAssertEqual(afterB.consumed.calories, 300, "removing a pending row does not change consumed")
    }

    /// `requestDelete` optimistically removes the row and buffers it, no request.
    func test_requestDelete_optimisticallyRemovesAndBuffers() async {
        var called = false
        let auth = signedInAuth { req in called = true; return (self.http(req, 204), Data()) }
        let a = entry(UUID(), kcal: 300)
        let model = DayMacroModel(date: Date(), auth: auth, undoWindow: .seconds(600))
        model.setStateForTesting(.loaded(summary([a], consumed: 300)))

        model.requestDelete([a])

        XCTAssertEqual(model.pendingDelete, DayMacroModel.BufferedDelete(entries: [a]))
        if case .loaded(let s) = model.state {
            XCTAssertTrue(s.entries.isEmpty)
            XCTAssertEqual(s.consumed.calories, 0)
        } else { XCTFail("expected loaded state") }
        XCTAssertFalse(called, "no DELETE fires during the undo window")

        model.undoDelete() // cancel the pending timer task
    }

    /// `undoDelete` restores the snapshot and sends no request.
    func test_undoDelete_restoresSnapshotNoRequest() async {
        var called = false
        let auth = signedInAuth { req in called = true; return (self.http(req, 204), Data()) }
        let a = entry(UUID(), kcal: 300)
        let model = DayMacroModel(date: Date(), auth: auth, undoWindow: .seconds(600))
        model.setStateForTesting(.loaded(summary([a], consumed: 300)))

        model.requestDelete([a])
        model.undoDelete()

        XCTAssertNil(model.pendingDelete)
        if case .loaded(let s) = model.state {
            XCTAssertEqual(s.entries.map(\.id), [a.id])
            XCTAssertEqual(s.consumed.calories, 300)
        } else { XCTFail("expected loaded state") }
        XCTAssertFalse(called)
    }

    /// `flushPendingDelete` fires the buffered DELETE and clears the buffer.
    func test_flushPendingDelete_firesDeleteAndClears() async {
        var deletePaths: [String] = []
        let a = entry(UUID(), kcal: 300)
        let auth = signedInAuth { req in
            if req.httpMethod == "DELETE" { deletePaths.append(req.url!.path) }
            // Any GET (the reload) returns the now-empty day.
            let body = #"{"date":"2026-06-22","target":{"calories":2000,"protein_g":150,"carbs_g":200,"fat_g":60,"target_weight_lb":null},"consumed":{"calories":0,"protein_g":0,"carbs_g":0,"fat_g":0},"remaining":{"calories":2000,"protein_g":150,"carbs_g":200,"fat_g":60},"entries":[]}"#
            return (self.http(req, req.httpMethod == "DELETE" ? 204 : 200), Data(body.utf8))
        }
        let model = DayMacroModel(date: Date(), auth: auth, undoWindow: .seconds(600))
        model.setStateForTesting(.loaded(summary([a], consumed: 300)))

        model.requestDelete([a])
        await model.flushPendingDelete()

        XCTAssertEqual(deletePaths, ["/entries/\(a.id.uuidString.lowercased())"])
        XCTAssertNil(model.pendingDelete)
    }
}
```

Note this test needs a `setStateForTesting(_:)` seam because `state` is `private(set)`. Add it in Step 3 (a `#if DEBUG` test hook or an internal setter).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && source .envrc && xcodegen generate && xcodebuild -project Pulse.xcodeproj -scheme Pulse -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:PulseTests/DeferredDeleteTests 2>&1 | tail -30`
Expected: FAIL to compile — missing `undoWindow:` init param, `BufferedDelete`, `pendingDelete`, `requestDelete`, `undoDelete`, `flushPendingDelete`, `summary(_:removing:)`, `setStateForTesting`.

- [ ] **Step 3a: Add the stored state + init param**

In `ios/Pulse/State/DayMacroModel.swift`:

Add properties after `pendingState` (from Task 5):

```swift
    /// Entries removed optimistically and awaiting the deferred `DELETE`; `nil`
    /// when no delete is pending. The view shows the undo snackbar while set.
    private(set) var pendingDelete: BufferedDelete?
    /// Pre-delete summary restored on undo.
    private var deleteSnapshot: DailySummary?
    /// The in-flight 10s commit task, cancelled by undo / replaced by a new delete.
    private var deleteCommitTask: Task<Void, Never>?
    /// How long the undo window stays open before the delete commits.
    private let undoWindow: Duration

    /// A buffered, not-yet-committed delete shown behind the undo snackbar.
    struct BufferedDelete: Equatable {
        let entries: [FoodEntry]
    }
```

Change the initializer to accept the window (default 10s):

```swift
    /// Initializes the model for a specific calendar day.
    /// Inputs:
    ///   - date: the day whose summary will be fetched.
    ///   - auth: auth session used to construct an authenticated client.
    ///   - undoWindow: how long swipe-delete stays undoable before committing
    ///     (default 10s; tests pass a long value to drive commit explicitly).
    init(date: Date, auth: AuthSession, undoWindow: Duration = .seconds(10)) {
        self.date = date
        self.auth = auth
        self.undoWindow = undoWindow
    }
```

Add a test seam after the init:

```swift
    #if DEBUG
    /// Test-only setter for `state` so deferred-delete tests can preload a day
    /// without stubbing the summary fetch. Not used in production code.
    /// - Parameter newState: the state to install.
    /// - Returns: Nothing.
    func setStateForTesting(_ newState: LoadState<DailySummary>) {
        state = newState
    }
    #endif
```

- [ ] **Step 3b: Add the optimistic-summary helper**

Add to `DayMacroModel` (e.g. after `makeCreate`):

```swift
    /// Returns a copy of `summary` with `entries` removed and the totals
    /// recomputed. Only **confirmed** removed entries reduce `consumed`
    /// (pending entries never counted), and `remaining` is recomputed from the
    /// unchanged targets.
    /// - Parameters:
    ///   - summary: The current day summary.
    ///   - entries: The entries being removed.
    /// - Returns: A new `DailySummary` reflecting the removal.
    static func summary(_ summary: DailySummary, removing entries: [FoodEntry]) -> DailySummary {
        let removedIds = Set(entries.map(\.id))
        let kept = summary.entries.filter { !removedIds.contains($0.id) }
        let removedConfirmed = entries.filter(\.isConfirmed)
        let calories = removedConfirmed.reduce(0) { $0 + $1.calories }
        let protein = removedConfirmed.reduce(0.0) { $0 + $1.proteinG }
        let carbs = removedConfirmed.reduce(0.0) { $0 + $1.carbsG }
        let fat = removedConfirmed.reduce(0.0) { $0 + $1.fatG }
        let consumed = MacroTotals(
            calories: summary.consumed.calories - calories,
            proteinG: summary.consumed.proteinG - protein,
            carbsG: summary.consumed.carbsG - carbs,
            fatG: summary.consumed.fatG - fat
        )
        let remaining = MacroTotals(
            calories: summary.target.calories - consumed.calories,
            proteinG: summary.target.proteinG - consumed.proteinG,
            carbsG: summary.target.carbsG - consumed.carbsG,
            fatG: summary.target.fatG - consumed.fatG
        )
        return DailySummary(
            date: summary.date, target: summary.target,
            consumed: consumed, remaining: remaining, entries: kept
        )
    }
```

- [ ] **Step 3c: Add the request/undo/commit/flush methods**

Add to `DayMacroModel` (near the existing delete methods):

```swift
    /// Optimistically removes `entries` from the loaded day and opens a 10s undo
    /// window before the actual `DELETE`s fire. The rows disappear and the totals
    /// adjust immediately; nothing is sent to the server until the window
    /// expires (or `flushPendingDelete` is called). Starting a new delete while
    /// one is buffered commits the previous one first. No-op when not loaded or
    /// `entries` is empty.
    /// - Parameter entries: The entries to delete.
    /// - Returns: Nothing; mutates `state` and `pendingDelete`.
    func requestDelete(_ entries: [FoodEntry]) {
        guard !entries.isEmpty, case .loaded(let current) = state else { return }
        if let outstanding = pendingDelete {
            deleteCommitTask?.cancel()
            let prior = outstanding.entries
            Task { await self.sendBufferedDeletes(prior) }
        }
        deleteSnapshot = current
        state = .loaded(Self.summary(current, removing: entries))
        pendingDelete = BufferedDelete(entries: entries)
        deleteCommitTask = Task { [undoWindow] in
            try? await Task.sleep(for: undoWindow)
            guard !Task.isCancelled else { return }
            await self.commitPendingDelete()
        }
    }

    /// Cancels the pending delete and restores the pre-delete summary. No server
    /// request is ever sent for the buffered entries.
    /// - Returns: Nothing; mutates `state` and clears the buffer.
    func undoDelete() {
        deleteCommitTask?.cancel()
        deleteCommitTask = nil
        if let snapshot = deleteSnapshot {
            state = .loaded(snapshot)
        }
        deleteSnapshot = nil
        pendingDelete = nil
    }

    /// Commits the buffered delete: fires the actual `DELETE`s then reloads the
    /// day to reconcile (any rows that failed to delete reappear on reload).
    /// No-op when nothing is buffered.
    /// - Returns: Nothing; clears the buffer and reloads `state`.
    func commitPendingDelete() async {
        guard let buffered = pendingDelete else { return }
        deleteCommitTask?.cancel()
        deleteCommitTask = nil
        pendingDelete = nil
        deleteSnapshot = nil
        await sendBufferedDeletes(buffered.entries)
        await load()
    }

    /// Commits any buffered delete immediately. Call from `.onDisappear` /
    /// scenephase background so a pending delete is not silently dropped.
    /// - Returns: Nothing.
    func flushPendingDelete() async {
        await commitPendingDelete()
    }

    /// Fires the buffered server deletes without touching view state (used when a
    /// new delete supersedes a still-pending one). Delegates to `deleteEntries`,
    /// which treats 404 as already-deleted.
    /// - Parameter entries: The entries to delete on the server.
    /// - Returns: Nothing.
    private func sendBufferedDeletes(_ entries: [FoodEntry]) async {
        _ = await deleteEntries(entries)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios && source .envrc && xcodegen generate && xcodebuild -project Pulse.xcodeproj -scheme Pulse -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:PulseTests/DeferredDeleteTests 2>&1 | tail -20`
Expected: PASS (all four tests).

- [ ] **Step 5: Commit**

```bash
git add ios/Pulse/State/DayMacroModel.swift ios/PulseTests/DeferredDeleteTests.swift ios/project.yml
git commit -m "feat(ios): add deferred-delete buffer with optimistic totals + undo"
```

---

## Task 7: iOS — `SwipeActionsRow` component

**Files:**
- Create: `ios/Pulse/Views/Components/SwipeActionsRow.swift`
- (No unit test — SwiftUI gesture view; verified by build + manual. A lightweight logic test of the action model is included.)
- Test: Create `ios/PulseTests/SwipeActionsRowTests.swift`

**Interfaces:**
- Produces:
  - `struct SwipeAction: Identifiable { let id = UUID(); let label: String; let systemImage: String; let tint: Color; let role: SwipeAction.Role; let handler: () -> Void }` with `enum Role { case normal, destructive }`
  - `struct SwipeActionsRow<Content: View>: View { init(actions: [SwipeAction], @ViewBuilder content: () -> Content) }`

- [ ] **Step 1: Write the failing test**

Create `ios/PulseTests/SwipeActionsRowTests.swift` (tests only the action value type's wiring — that a handler fires and role/label are stored; the gesture/visuals are manual):

```swift
// PulseTests/SwipeActionsRowTests.swift
import XCTest
import SwiftUI
@testable import Pulse

/// Logic-level tests for `SwipeAction` (the value type backing
/// `SwipeActionsRow`). The swipe gesture and rendering are verified manually.
final class SwipeActionsRowTests: XCTestCase {
    func test_swipeAction_storesFieldsAndFiresHandler() {
        var fired = false
        let action = SwipeAction(
            label: "Delete", systemImage: "trash", tint: Theme.CTP.red,
            role: .destructive, handler: { fired = true }
        )
        XCTAssertEqual(action.label, "Delete")
        XCTAssertEqual(action.role, .destructive)
        action.handler()
        XCTAssertTrue(fired)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && source .envrc && xcodegen generate && xcodebuild -project Pulse.xcodeproj -scheme Pulse -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:PulseTests/SwipeActionsRowTests 2>&1 | tail -30`
Expected: FAIL to compile — `cannot find 'SwipeAction' in scope`.

- [ ] **Step 3: Write the component**

Create `ios/Pulse/Views/Components/SwipeActionsRow.swift`:

```swift
/// A reusable swipe-to-reveal-actions row for non-`List` content. The day view
/// is a `ScrollView` of bespoke `ctpCard`s, so SwiftUI's `.swipeActions`
/// (List-only) is unavailable; this wraps any row content and reveals trailing
/// action buttons on a leftward drag. Every action requires an explicit tap —
/// there is no full-swipe auto-trigger.
import SwiftUI

/// One trailing action shown when a `SwipeActionsRow` is open.
struct SwipeAction: Identifiable {
    /// Visual/semantic weight of an action.
    enum Role {
        case normal
        case destructive
    }

    let id = UUID()
    let label: String
    let systemImage: String
    let tint: Color
    let role: Role
    let handler: () -> Void

    /// Creates a swipe action.
    /// - Parameters:
    ///   - label: Accessible/visible label (e.g. "Delete").
    ///   - systemImage: SF Symbol name shown above the label.
    ///   - tint: Background tint of the action button.
    ///   - role: `.destructive` for deletes, `.normal` otherwise.
    ///   - handler: Invoked when the user taps the revealed button.
    init(label: String, systemImage: String, tint: Color, role: Role = .normal, handler: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
        self.role = role
        self.handler = handler
    }
}

/// Wraps `content` and reveals `actions` as trailing buttons on a left drag.
struct SwipeActionsRow<Content: View>: View {
    private let actions: [SwipeAction]
    private let content: Content

    /// Width of each revealed action button.
    private static var buttonWidth: CGFloat { 72 }
    /// Current horizontal offset of the row content (negative = revealed).
    @State private var offset: CGFloat = 0
    /// Offset captured at gesture start so drags are cumulative.
    @State private var startOffset: CGFloat = 0

    /// Creates a swipeable row.
    /// - Parameters:
    ///   - actions: Trailing actions revealed on swipe (leftmost shown first).
    ///   - content: The row content.
    init(actions: [SwipeAction], @ViewBuilder content: () -> Content) {
        self.actions = actions
        self.content = content()
    }

    /// Total width the open row reveals.
    private var revealWidth: CGFloat { CGFloat(actions.count) * Self.buttonWidth }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                ForEach(actions) { action in
                    Button {
                        close()
                        action.handler()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: action.systemImage)
                                .font(.system(size: 16, weight: .semibold))
                            Text(action.label)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Theme.FG.primary)
                        .frame(width: Self.buttonWidth)
                        .frame(maxHeight: .infinity)
                        .background(action.tint.opacity(action.role == .destructive ? 0.9 : 0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .opacity(offset < 0 ? 1 : 0)

            content
                .background(Theme.BG.primary)
                .offset(x: offset)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            let proposed = startOffset + value.translation.width
                            offset = min(0, max(-revealWidth, proposed))
                        }
                        .onEnded { _ in
                            let open = offset < -revealWidth / 2
                            withAnimation(.easeOut(duration: 0.2)) {
                                offset = open ? -revealWidth : 0
                            }
                            startOffset = offset
                        }
                )
        }
        .clipped()
    }

    /// Animates the row closed and resets the drag baseline.
    /// - Returns: Nothing.
    private func close() {
        withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
        startOffset = 0
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios && source .envrc && xcodegen generate && xcodebuild -project Pulse.xcodeproj -scheme Pulse -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:PulseTests/SwipeActionsRowTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Pulse/Views/Components/SwipeActionsRow.swift ios/PulseTests/SwipeActionsRowTests.swift ios/project.yml
git commit -m "feat(ios): add SwipeActionsRow custom swipe component"
```

---

## Task 8: iOS — `UndoSnackbar` overlay component

**Files:**
- Create: `ios/Pulse/Views/Components/UndoSnackbar.swift`
- (No unit test — visual overlay; verified by build + manual.)

**Interfaces:**
- Produces: a `View` extension `func undoSnackbar(isPresented: Bool, message: String, onUndo: @escaping () -> Void) -> some View` overlaying a bottom capsule with an "Undo" button while `isPresented`.

- [ ] **Step 1: Write the component (no test — visual)**

Create `ios/Pulse/Views/Components/UndoSnackbar.swift` (styled after `TransientConfirmation`, but action-bearing and driven by a `Bool`, since auto-dismiss is owned by the model's undo window):

```swift
/// A bottom "undo" snackbar overlay shown while a delete is in its undo window.
/// Unlike `TransientConfirmation` (self-dismissing chip), this carries an action
/// and stays visible as long as `isPresented` is true — the owning model's undo
/// window controls dismissal by clearing its `pendingDelete`.
import SwiftUI

private struct UndoSnackbarModifier: ViewModifier {
    let isPresented: Bool
    let message: String
    let onUndo: () -> Void

    /// Overlays the snackbar on `content` while `isPresented`.
    /// Inputs:
    ///   - content: the view the snackbar is layered over.
    /// Outputs: the composed view with the bottom undo overlay.
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isPresented {
                    HStack(spacing: 14) {
                        Text(message)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.FG.primary)
                        Button("Undo", action: onUndo)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.CTP.mauve)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(Theme.BG.secondary)
                            .overlay(Capsule().stroke(Theme.separator, lineWidth: 0.5)))
                    .padding(.bottom, Theme.Layout.dockClearance)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isPresented)
    }
}

extension View {
    /// Overlays a bottom undo snackbar while `isPresented`.
    /// Inputs:
    ///   - isPresented: whether the snackbar is shown.
    ///   - message: the snackbar text (e.g. "Entry deleted").
    ///   - onUndo: invoked when the user taps Undo.
    /// Outputs: a view with the undo overlay applied.
    func undoSnackbar(isPresented: Bool, message: String, onUndo: @escaping () -> Void) -> some View {
        modifier(UndoSnackbarModifier(isPresented: isPresented, message: message, onUndo: onUndo))
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd ios && source .envrc && xcodegen generate && xcodebuild -project Pulse.xcodeproj -scheme Pulse -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ios/Pulse/Views/Components/UndoSnackbar.swift ios/project.yml
git commit -m "feat(ios): add UndoSnackbar overlay component"
```

---

## Task 9: iOS — wire DayMacroView (swipe rows, pending pill + panel, undo snackbar)

**Files:**
- Modify: `ios/Pulse/Views/DayMacroView.swift`
- (No new unit test — view composition; verified by full build + manual. All logic it calls is already covered by Tasks 5–6.)

**Interfaces:**
- Consumes: `model.makePending`, `model.requestDelete`, `model.undoDelete`, `model.pendingDelete`, `model.confirmEntries`, `SwipeActionsRow`, `SwipeAction`, `.undoSnackbar`, the existing `DayRow`/`MealGroup`/`groupDayEntries`/`clusterByProximity`.

This task has several edits to one file. Build after each sub-step group.

- [ ] **Step 1: Add view state for the pending panel**

In `DayMacroView`, add near the other `@State` (after line 34):

```swift
    /// Whether the pending-items panel (behind the count pill) is expanded.
    @State private var pendingExpanded = false
    /// Whether the meal-group delete confirmation dialog is presented.
    @State private var showMealDeleteConfirm = false
    /// The meal group queued for deletion, pending dialog confirmation.
    @State private var mealPendingDeletion: MealGroup?
```

- [ ] **Step 2: Helper to resolve a `DayRow` to its entries**

Add this helper method to `DayMacroView`:

```swift
    /// The underlying `FoodEntry`s for a grouped row (one for a single, all
    /// items for a meal group).
    /// - Parameter row: The grouped day row.
    /// - Returns: Its entries.
    private func entries(of row: DayRow) -> [FoodEntry] {
        switch row {
        case .single(let entry): return [entry]
        case .meal(let group): return group.items
        }
    }
```

- [ ] **Step 3: Swipe-wrap confirmed rows in `clusterCard`**

Replace the `Group { ... switch row ... }` inside `clusterCard` (lines 470-477) with a `SwipeActionsRow` wrapper:

```swift
                SwipeActionsRow(actions: confirmedRowActions(row)) {
                    // Rows here are confirmed-only; pending entries render in the
                    // pending panel behind the count pill above.
                    Group {
                        switch row {
                        case .single(let entry): EntryRow(entry: entry)
                        case .meal(let group):   MealGroupRow(group: group)
                        }
                    }
                }
```

Add the action builder to `DayMacroView`:

```swift
    /// Swipe actions for a confirmed row: Make Pending and Delete. A single-food
    /// delete defers immediately (with undo); a meal-group delete first asks for
    /// confirmation (it removes several entries at once).
    /// - Parameter row: The confirmed grouped row.
    /// - Returns: The trailing swipe actions.
    private func confirmedRowActions(_ row: DayRow) -> [SwipeAction] {
        [
            SwipeAction(label: "Pending", systemImage: "clock.arrow.circlepath", tint: Theme.pending) {
                Task { await runMakePending(entries(of: row)) }
            },
            SwipeAction(label: "Delete", systemImage: "trash", tint: Theme.CTP.red, role: .destructive) {
                switch row {
                case .single(let entry):
                    model?.requestDelete([entry])
                case .meal(let group):
                    mealPendingDeletion = group
                    showMealDeleteConfirm = true
                }
            },
        ]
    }

    /// Runs a make-pending action and surfaces failure through the existing
    /// confirm-failure alert channel (reused for symmetry).
    /// - Parameter entries: The entries to make pending.
    /// - Returns: Nothing.
    private func runMakePending(_ entries: [FoodEntry]) async {
        guard let model else { return }
        model.resetPendingState()
        await model.makePending(entries)
    }
```

- [ ] **Step 4: Replace the always-visible pending section with a count pill + panel**

Replace the pending block in `loadedBody` (lines 244-247):

```swift
                if !isSelecting, !pendingRows.isEmpty {
                    pendingSection(pendingRows, allPending: pending)
                        .padding(.horizontal, 16)
                }
```

with:

```swift
                if !isSelecting, !pendingRows.isEmpty {
                    pendingPill(count: pending.count)
                        .padding(.horizontal, 16)
                    if pendingExpanded {
                        pendingPanel(pendingRows, allPending: pending)
                            .padding(.horizontal, 16)
                    }
                }
```

Add the pill + panel methods, and update the pending rows to be swipeable (Approve + Delete). Add to `DayMacroView`:

```swift
    /// Tappable count pill summarizing pending items; toggles the panel.
    /// - Parameter count: Number of pending entries.
    /// - Returns: The pill view.
    private func pendingPill(count: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { pendingExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(count) pending")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: pendingExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.pending)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.pending.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) pending items, tap to \(pendingExpanded ? "collapse" : "expand")")
    }

    /// Expanded panel listing each pending row, swipeable to Approve or Delete,
    /// with an "Approve all" action.
    /// - Parameters:
    ///   - rows: The pending rows.
    ///   - allPending: The flat pending entries (for "Approve all").
    /// - Returns: The panel view.
    private func pendingPanel(_ rows: [DayRow], allPending: [FoodEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    SwipeActionsRow(actions: pendingRowActions(row)) {
                        switch row {
                        case .single(let entry): EntryRow(entry: entry)
                        case .meal(let group):   MealGroupRow(group: group)
                        }
                    }
                    if idx < rows.count - 1 {
                        Rectangle().fill(Theme.separator).frame(height: 0.5)
                    }
                }
            }
            .padding(.horizontal, 14)
            .ctpCard(tint: Theme.pending.opacity(0.08))

            confirmAllBar(allPending)
        }
    }

    /// Swipe actions for a pending row: Approve (confirm) and Delete (deferred).
    /// - Parameter row: The pending grouped row.
    /// - Returns: The trailing swipe actions.
    private func pendingRowActions(_ row: DayRow) -> [SwipeAction] {
        let pendingItems = entries(of: row).filter { !$0.isConfirmed }
        return [
            SwipeAction(label: "Approve", systemImage: "checkmark.circle", tint: Theme.CTP.green) {
                Task { await runConfirm(pendingItems) }
            },
            SwipeAction(label: "Delete", systemImage: "trash", tint: Theme.CTP.red, role: .destructive) {
                switch row {
                case .single(let entry):
                    model?.requestDelete([entry])
                case .meal(let group):
                    mealPendingDeletion = group
                    showMealDeleteConfirm = true
                }
            },
        ]
    }
```

Then **delete the now-unused** `pendingSection`, `pendingSingleRow`, and `pendingMealRow` methods (lines 283-528 region — remove exactly those three methods; keep `confirmAllBar`, `clusteredEntries`, `clusterCard`, etc.).

- [ ] **Step 5: Mount the meal-delete dialog + undo snackbar, and flush on disappear**

Add these modifiers to the `body`'s `ZStack` (alongside the existing `.confirmationDialog`/`.alert`/`.transientConfirmation` chain, before or after `.transientConfirmation`):

```swift
        .confirmationDialog(
            "Delete this meal's \(mealPendingDeletion?.items.count ?? 0) entries? This can't be undone.",
            isPresented: $showMealDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let group = mealPendingDeletion { model?.requestDelete(group.items) }
                mealPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { mealPendingDeletion = nil }
        }
        .undoSnackbar(
            isPresented: model?.pendingDelete != nil,
            message: undoMessage,
            onUndo: { model?.undoDelete() }
        )
        .onDisappear { Task { await model?.flushPendingDelete() } }
```

Add the message helper:

```swift
    /// Snackbar text for the current buffered delete (singular/plural aware).
    private var undoMessage: String {
        let count = model?.pendingDelete?.entries.count ?? 0
        return count == 1 ? "Entry deleted" : "\(count) entries deleted"
    }
```

- [ ] **Step 6: Build + full test run**

Run:
```bash
cd ios && source .envrc && xcodegen generate && \
xcodebuild -project Pulse.xcodeproj -scheme Pulse -destination 'platform=iOS Simulator,name=iPhone 15' test 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **` (whole `PulseTests` suite green, including Tasks 4–7).

- [ ] **Step 7: Manual verification (simulator)**

Launch the app, open Today:
- Swipe a counted row → reveals **Pending** + **Delete**.
- Tap **Pending** → row dims, leaves the list, totals drop, the **N pending** pill appears.
- Tap **Delete** on a single food → row vanishes, **undo snackbar** appears; tap **Undo** within 10s → it returns. Let it expire → it stays gone after reload.
- Tap the **pending pill** → panel expands; swipe a pending row → **Approve** / **Delete**; "Approve all" still works.
- Swipe-delete a **meal group** row → confirmation dialog first, then undo snackbar.

- [ ] **Step 8: Commit**

```bash
git add ios/Pulse/Views/DayMacroView.swift ios/project.yml
git commit -m "feat(ios): swipe actions on intake rows + pending pill/panel with undo"
```

---

## Self-Review

**1. Spec coverage:**
- Server inverse-of-confirm (`unconfirm`) — Tasks 1-3. ✓
- iOS client `makePending` + wire model — Task 4. ✓
- `DayMacroModel.makePending` + `pendingState` — Task 5. ✓
- Deferred-delete buffer with optimistic totals + undo (single + meal flush) — Task 6. ✓
- `SwipeActionsRow` custom swipe (Approach A) — Task 7. ✓
- Undo snackbar — Task 8. ✓
- Confirmed-row swipe (Make Pending + Delete; meal delete confirm dialog) — Task 9. ✓
- Replace inline pending section with count pill + expandable panel (swipe Approve/Delete + Approve all) — Task 9. ✓
- Meal-group rows act on all items — Task 9 (`entries(of:)`, `requestDelete(group.items)`, `pendingRowActions` filters to pending items). ✓
- Flush on disappear/background — Task 9 (`.onDisappear`). ✓ (Scenephase background is optional; `.onDisappear` covers tab/nav changes — acceptable for v1.)

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**3. Type consistency:**
- Server `unconfirm_entries` (repo + service) and endpoint function `make_entries_pending` (distinct to avoid shadowing) — consistent across Tasks 1-3. ✓
- iOS `makePending(ids:)` (client) / `makePending(_:)` (model) / `EntriesPendingRequest` / `EntryWriteResponse` / `PendingState` / `BufferedDelete` / `requestDelete`/`undoDelete`/`commitPendingDelete`/`flushPendingDelete`/`summary(_:removing:)` — names match between definition (Tasks 4-6) and use (Task 9). ✓
- `Theme.pending` referenced in Task 9 is already used by the existing `pendingSection`/`PendingBadge`, so it exists. ✓

**Note for executor:** Integration tests (Tasks 1-2) need `TEST_DATABASE_URL`. If unavailable in the execution environment, run the unit suite (`uv run pytest tests/ -q`) and the endpoint tests (Task 3, which mock the service) and flag the integration tests as run-pending.
