// PulseTests/DeleteEntriesTests.swift
import XCTest
@testable import Pulse

/// Unit tests for the "delete selected entries" loop (`DayMacroModel.deleteEntries`).
/// Verifies full-success, partial-failure remainder/retry, 404-as-success,
/// signed-out, and unauthorized handling.
final class DeleteEntriesTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private let testAccount = "delete-entries-\(UUID().uuidString)"
    private var activeStubs: [StubURLProtocol.Registration] = []

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        _ = KeychainStore.delete(service: testService, account: testAccount)
        super.tearDown()
    }

    /// Builds a `FoodEntry` with sensible defaults; only `id` matters for deletes.
    private func entry(id: UUID = UUID()) -> FoodEntry {
        FoodEntry(
            id: id,
            dailyLogId: UUID(),
            userKey: "khash",
            entryGroupId: UUID(),
            displayName: "Oats, raw",
            quantityText: "80 g",
            normalizedQuantityValue: 80,
            normalizedQuantityUnit: "g",
            usdaFdcId: nil,
            usdaDescription: nil,
            customFoodId: nil,
            calories: 320,
            proteinG: 10,
            carbsG: 54,
            fatG: 6,
            mealId: nil,
            mealName: nil,
            consumedAt: .now,
            createdAt: .now
        )
    }

    /// Thread-safe call counter for stubbed responders invoked off the test thread.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        /// Increments and returns the new call number (1-based).
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count
        }
        /// The total number of calls recorded so far.
        var total: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    /// Builds a signed-in `AuthSession` wired to a stubbed URL session.
    private func signedInAuth(responder: @escaping StubURLProtocol.Responder) -> AuthSession {
        let stub = StubURLProtocol.makeSession(responder: responder)
        activeStubs.append(stub)
        _ = KeychainStore.write(
            #"{"token":"tok","email":"khashzd@gmail.com"}"#,
            service: testService,
            account: testAccount
        )
        return AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: stub.session
        )
    }

    /// Builds a signed-out `AuthSession` so `makeClient()` returns nil.
    private func signedOutAuth() -> AuthSession {
        _ = KeychainStore.delete(service: testService, account: testAccount)
        return AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
    }

    private func http(_ req: URLRequest, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    func test_deleteEntries_allSucceed_finishesWithNoRemainder() async {
        let auth = signedInAuth { req in (self.http(req, 204), Data()) }
        let model = DayMacroModel(date: Date(), auth: auth)

        let remaining = await model.deleteEntries([entry(), entry()])

        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(model.deleteState, .finished(deleted: 2))
    }

    func test_deleteEntries_partialFailure_returnsRemainderAndRetryDoesNotRepeat() async {
        let counter = CallCounter()
        // Fail only the 2nd request; succeed on every other call.
        let auth = signedInAuth { req in
            let n = counter.next()
            return n == 2 ? (self.http(req, 500), Data()) : (self.http(req, 204), Data())
        }
        let model = DayMacroModel(date: Date(), auth: auth)
        let first = entry()
        let second = entry()

        // First run: first item deletes, second item fails.
        let remaining = await model.deleteEntries([first, second])
        XCTAssertEqual(remaining.map(\.id), [second.id], "only the failed item should remain")
        XCTAssertEqual(model.deleteState, .failed(deleted: 1, error: .server(status: 500)))

        // Retry the remainder: it succeeds.
        let stillRemaining = await model.deleteEntries(remaining)
        XCTAssertTrue(stillRemaining.isEmpty)
        XCTAssertEqual(model.deleteState, .finished(deleted: 1))

        // Three DELETEs total: first once, second twice (one failure + one success).
        // The already-deleted first item was never re-sent.
        XCTAssertEqual(counter.total, 3)
    }

    func test_deleteEntries_404CountsAsDeletedAndLoopContinues() async {
        let counter = CallCounter()
        // First entry is already gone on the server (404); second deletes normally.
        let auth = signedInAuth { req in
            let n = counter.next()
            return n == 1 ? (self.http(req, 404), Data()) : (self.http(req, 204), Data())
        }
        let model = DayMacroModel(date: Date(), auth: auth)

        let remaining = await model.deleteEntries([entry(), entry()])

        XCTAssertTrue(remaining.isEmpty, "a 404 must not stop the loop")
        XCTAssertEqual(model.deleteState, .finished(deleted: 2))
        XCTAssertEqual(counter.total, 2)
    }

    func test_deleteEntries_notSignedIn_returnsAllAndReportsFailure() async {
        let model = DayMacroModel(date: Date(), auth: signedOutAuth())
        let only = entry()

        let remaining = await model.deleteEntries([only])

        XCTAssertEqual(remaining.map(\.id), [only.id])
        XCTAssertEqual(model.deleteState, .failed(deleted: 0, error: .notSignedIn))
    }

    func test_deleteEntries_unauthorized_failsAndSignsOut() async {
        let auth = signedInAuth { req in (self.http(req, 401), Data()) }
        let model = DayMacroModel(date: Date(), auth: auth)
        let only = entry()

        let remaining = await model.deleteEntries([only])

        XCTAssertEqual(remaining.map(\.id), [only.id])
        XCTAssertEqual(model.deleteState, .failed(deleted: 0, error: .unauthorized))
        XCTAssertFalse(auth.isSignedIn, "401 must route through handleUnauthorized")
    }

    func test_resetDeleteState_returnsToIdle() async {
        let auth = signedInAuth { req in (self.http(req, 204), Data()) }
        let model = DayMacroModel(date: Date(), auth: auth)
        _ = await model.deleteEntries([entry()])
        XCTAssertEqual(model.deleteState, .finished(deleted: 1))

        model.resetDeleteState()

        XCTAssertEqual(model.deleteState, .idle)
    }
}
