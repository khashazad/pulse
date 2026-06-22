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
