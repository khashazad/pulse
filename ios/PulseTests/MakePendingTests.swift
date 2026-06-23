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
