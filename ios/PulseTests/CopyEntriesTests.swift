// PulseTests/CopyEntriesTests.swift
import XCTest
@testable import Pulse

/// Unit tests for the "copy existing entries to another day" mapping
/// (`DayMacroModel.makeCreate`). Verifies USDA vs. custom source selection,
/// macro/quantity preservation, backdated `consumed_at`, and the skip case for
/// entries that reference no recreatable food source.
final class CopyEntriesTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private let testAccount = "copy-entries-\(UUID().uuidString)"
    private var activeStubs: [StubURLProtocol.Registration] = []

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        _ = KeychainStore.delete(service: testService, account: testAccount)
        super.tearDown()
    }

    /// Builds a `FoodEntry` with sensible defaults, overridable per test.
    private func entry(
        usdaFdcId: Int? = nil,
        usdaDescription: String? = nil,
        customFoodId: UUID? = nil
    ) -> FoodEntry {
        FoodEntry(
            id: UUID(),
            dailyLogId: UUID(),
            userKey: "khash",
            entryGroupId: UUID(),
            displayName: "Oats, raw",
            quantityText: "80 g",
            normalizedQuantityValue: 80,
            normalizedQuantityUnit: "g",
            usdaFdcId: usdaFdcId,
            usdaDescription: usdaDescription,
            customFoodId: customFoodId,
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

    func test_makeCreate_usdaSource_preservesFieldsAndBackdates() throws {
        let target = DateOnly.formatter.date(from: "2026-05-29")!
        let src = entry(usdaFdcId: 173904, usdaDescription: "Oats, raw")

        let created = try XCTUnwrap(DayMacroModel.makeCreate(from: src, consumedAt: target))

        XCTAssertEqual(created.usdaFdcId, 173904)
        XCTAssertEqual(created.usdaDescription, "Oats, raw")
        XCTAssertNil(created.customFoodId, "USDA copy must not carry a custom_food_id")
        XCTAssertEqual(created.displayName, "Oats, raw")
        XCTAssertEqual(created.quantityText, "80 g")
        XCTAssertEqual(created.calories, 320)
        XCTAssertEqual(created.proteinG, 10)
        XCTAssertEqual(created.normalizedQuantityValue, 80)
        XCTAssertEqual(created.normalizedQuantityUnit, "g")
        XCTAssertEqual(created.consumedAt, target)
    }

    func test_makeCreate_customSource_preservesFieldsAndBackdates() throws {
        let target = DateOnly.formatter.date(from: "2026-05-29")!
        let customId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let src = entry(customFoodId: customId)

        let created = try XCTUnwrap(DayMacroModel.makeCreate(from: src, consumedAt: target))

        XCTAssertEqual(created.customFoodId, customId)
        XCTAssertNil(created.usdaFdcId, "custom copy must not carry a usda_fdc_id")
        XCTAssertNil(created.usdaDescription)
        XCTAssertEqual(created.calories, 320)
        XCTAssertEqual(created.consumedAt, target)
    }

    func test_makeCreate_usdaTakesPrecedenceWhenBothPresent() throws {
        // Defensive: a row carrying both refs should recreate as USDA (matches the
        // server's "exactly one source" contract by picking USDA first).
        let target = DateOnly.formatter.date(from: "2026-05-29")!
        let src = entry(
            usdaFdcId: 173904,
            usdaDescription: "Oats, raw",
            customFoodId: UUID()
        )

        let created = try XCTUnwrap(DayMacroModel.makeCreate(from: src, consumedAt: target))
        XCTAssertEqual(created.usdaFdcId, 173904)
        XCTAssertNil(created.customFoodId)
    }

    func test_makeCreate_noSource_returnsNil() {
        let target = DateOnly.formatter.date(from: "2026-05-29")!
        let src = entry()  // neither USDA nor custom
        XCTAssertNil(
            DayMacroModel.makeCreate(from: src, consumedAt: target),
            "entries with no recreatable source must be skipped"
        )
    }

    func test_makeCreate_usdaMissingDescription_returnsNil() {
        // The server requires usda_description whenever usda_fdc_id is set; an
        // entry missing it cannot be recreated as USDA and has no custom fallback.
        let target = DateOnly.formatter.date(from: "2026-05-29")!
        let src = entry(usdaFdcId: 173904, usdaDescription: nil)
        XCTAssertNil(DayMacroModel.makeCreate(from: src, consumedAt: target))
    }

    // MARK: - copyEntries loop

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

    /// Builds a signed-in `AuthSession` (session blob written to a test keychain
    /// slot, matching `ModelUnauthorizedTests`) wired to a stubbed URL session.
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

    /// Builds a signed-out `AuthSession` (empty keychain slot) so `makeClient()`
    /// returns nil.
    private func signedOutAuth() -> AuthSession {
        _ = KeychainStore.delete(service: testService, account: testAccount)
        return AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle(for: Self.self).url(forResource: name, withExtension: "json")!)
    }

    private func http(_ req: URLRequest, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    func test_copyEntries_allSucceed_finishesWithNoRemainder() async throws {
        let body = try fixture("entries_create")
        let auth = signedInAuth { req in (self.http(req, 201), body) }
        let model = DayMacroModel(date: Date(), auth: auth)
        let target = DateOnly.formatter.date(from: "2026-05-29")!

        let remaining = await model.copyEntries(
            [entry(usdaFdcId: 173904, usdaDescription: "Oats"),
             entry(usdaFdcId: 171711, usdaDescription: "Blueberries")],
            to: target
        )

        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(model.copyState, .finished(copied: 2, skipped: 0))
    }

    func test_copyEntries_partialFailure_preservesCopiedAndRetryDoesNotDuplicate() async throws {
        let body = try fixture("entries_create")
        let counter = CallCounter()
        // Fail only the 2nd request; succeed on every other call.
        let auth = signedInAuth { req in
            let n = counter.next()
            return n == 2 ? (self.http(req, 500), Data()) : (self.http(req, 201), body)
        }
        let model = DayMacroModel(date: Date(), auth: auth)
        let first = entry(usdaFdcId: 173904, usdaDescription: "Oats")
        let second = entry(usdaFdcId: 171711, usdaDescription: "Blueberries")
        let target = DateOnly.formatter.date(from: "2026-05-29")!

        // First run: first item saves, second item fails.
        let remaining = await model.copyEntries([first, second], to: target)
        XCTAssertEqual(remaining.map(\.id), [second.id], "only the failed item should remain")
        XCTAssertEqual(model.copyState, .failed(copied: 1, error: .server(status: 500)))

        // Retry the remainder: it succeeds.
        let stillRemaining = await model.copyEntries(remaining, to: target)
        XCTAssertTrue(stillRemaining.isEmpty)
        XCTAssertEqual(model.copyState, .finished(copied: 1, skipped: 0))

        // Three POSTs total: first once, second twice (one failure + one success).
        // The already-saved first item was never re-sent → no duplication.
        XCTAssertEqual(counter.total, 3)
    }

    func test_copyEntries_allUnrecreatable_finishesWithZeroCopiedAndNoRequests() async {
        var calls = 0
        let auth = signedInAuth { req in
            calls += 1
            return (self.http(req, 201), Data())
        }
        let model = DayMacroModel(date: Date(), auth: auth)

        let remaining = await model.copyEntries([entry(), entry()], to: Date())

        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(model.copyState, .finished(copied: 0, skipped: 2))
        XCTAssertEqual(calls, 0, "unrecreatable entries must not hit the network")
    }

    func test_copyEntries_notSignedIn_returnsAllAndReportsFailure() async {
        let model = DayMacroModel(date: Date(), auth: signedOutAuth())
        let only = entry(usdaFdcId: 1, usdaDescription: "x")

        let remaining = await model.copyEntries([only], to: Date())

        XCTAssertEqual(remaining.map(\.id), [only.id])
        XCTAssertEqual(model.copyState, .failed(copied: 0, error: .notSignedIn))
    }
}
