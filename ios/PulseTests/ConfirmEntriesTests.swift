// PulseTests/ConfirmEntriesTests.swift
import XCTest
@testable import Pulse

/// Unit tests for `DayMacroModel.confirmEntries` — the action that confirms
/// pending prep entries. Covers the empty/guard, signed-out, server-error, and
/// unauthorized branches. The success path (one confirm request followed by a
/// day reload) is a straight composition of `PulseClient.confirmEntries`
/// (covered by `EntryWriteClientTests`) and `load()` (covered elsewhere), so it
/// is not re-exercised here.
final class ConfirmEntriesTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private let testAccount = "confirm-entries-\(UUID().uuidString)"
    private var activeStubs: [StubURLProtocol.Registration] = []

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        _ = KeychainStore.delete(service: testService, account: testAccount)
        super.tearDown()
    }

    /// Builds a pending `FoodEntry`; only `id`/`isConfirmed` matter for confirm.
    private func entry(id: UUID = UUID()) -> FoodEntry {
        FoodEntry(
            id: id, dailyLogId: UUID(), userKey: "khash", entryGroupId: UUID(),
            displayName: "Prep bowl", quantityText: "1 portion",
            normalizedQuantityValue: nil, normalizedQuantityUnit: nil,
            usdaFdcId: 1, usdaDescription: "Bowl", customFoodId: nil,
            calories: 600, proteinG: 50, carbsG: 40, fatG: 20,
            mealId: nil, mealName: nil, consumedAt: .now, createdAt: .now,
            isConfirmed: false
        )
    }

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

    func test_confirmEntries_empty_finishesWithoutRequest() async {
        var called = false
        let auth = signedInAuth { req in
            called = true
            return (self.http(req, 200), Data())
        }
        let model = DayMacroModel(date: Date(), auth: auth)

        await model.confirmEntries([])

        XCTAssertEqual(model.confirmState, .finished(confirmed: 0))
        XCTAssertFalse(called, "an empty confirm must not hit the network")
    }

    func test_confirmEntries_notSignedIn_reportsFailure() async {
        let model = DayMacroModel(date: Date(), auth: signedOutAuth())

        await model.confirmEntries([entry()])

        XCTAssertEqual(model.confirmState, .failed(.notSignedIn))
    }

    func test_confirmEntries_serverError_reportsFailure() async {
        let auth = signedInAuth { req in (self.http(req, 500), Data()) }
        let model = DayMacroModel(date: Date(), auth: auth)

        await model.confirmEntries([entry()])

        XCTAssertEqual(model.confirmState, .failed(.server(status: 500)))
    }

    func test_confirmEntries_unauthorized_failsAndSignsOut() async {
        let auth = signedInAuth { req in (self.http(req, 401), Data()) }
        let model = DayMacroModel(date: Date(), auth: auth)

        await model.confirmEntries([entry()])

        XCTAssertEqual(model.confirmState, .failed(.unauthorized))
        XCTAssertFalse(auth.isSignedIn, "401 must route through handleUnauthorized")
    }

    func test_resetConfirmState_returnsToIdle() async {
        let model = DayMacroModel(date: Date(), auth: signedOutAuth())
        await model.confirmEntries([entry()])
        XCTAssertEqual(model.confirmState, .failed(.notSignedIn))

        model.resetConfirmState()

        XCTAssertEqual(model.confirmState, .idle)
    }
}
