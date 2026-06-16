// PulseTests/FoodsModelTests.swift
import XCTest
@testable import Pulse

/// Tests FoodsModel's dual-load success path and portion→CustomFood resolution.
final class FoodsModelTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private var activeStubs: [StubURLProtocol.Registration] = []
    /// Retains AuthSessions for the test's lifetime: FoodsModel holds `weak var
    /// auth`, so without a strong reference here the session deallocates and
    /// `makeClient()` returns nil (surfacing as `.notSignedIn`).
    private var retainedAuths: [AuthSession] = []
    /// Per-test keychain slots written by `makeAuth`, deleted on teardown.
    private var keychainAccounts: [String] = []

    /// Loads a JSON fixture from the test bundle.
    /// Inputs:
    ///   - name: fixture file name without the `.json` extension.
    /// Outputs: the fixture's raw bytes.
    /// Throws: when the resource is missing or unreadable.
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    /// Builds a signed-in `AuthSession` whose client routes `/foods` and
    /// `/custom-foods` to their fixtures with 200s, retaining it for the test's
    /// lifetime. Thin wrapper over `makeAuth(foodsStatus:customFoodsStatus:)`.
    /// Outputs: the signed-in session.
    /// Throws: when a fixture cannot be loaded.
    private func makeAuth() throws -> AuthSession {
        try makeAuth(foodsStatus: 200, customFoodsStatus: 200)
    }

    /// Builds a signed-in `AuthSession` whose client routes `/foods` and
    /// `/custom-foods` to their fixtures, letting a test pick the HTTP status
    /// returned per path. A path given a non-2xx status responds with that
    /// status and empty data so the client maps it to a failure; the fixture
    /// body is only attached on success statuses. The session is retained for
    /// the test's lifetime.
    /// Inputs:
    ///   - foodsStatus: HTTP status to return for `GET /foods`.
    ///   - customFoodsStatus: HTTP status to return for `GET /custom-foods`.
    /// Outputs: the signed-in session.
    /// Throws: when a fixture cannot be loaded.
    private func makeAuth(foodsStatus: Int, customFoodsStatus: Int) throws -> AuthSession {
        let foods = try fixture("foods")
        let customs = try fixture("custom_foods")
        let stub = StubURLProtocol.makeSession { req in
            let isFoods = req.url?.path == "/foods"
            let status = isFoods ? foodsStatus : customFoodsStatus
            let body: Data = (200..<300).contains(status) ? (isFoods ? foods : customs) : Data()
            return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
        }
        activeStubs.append(stub)
        let account = "fmt-\(UUID().uuidString)"
        keychainAccounts.append(account)
        let auth = AuthSession.signedInStub(
            session: stub.session,
            keychainService: testService,
            keychainAccount: account
        )
        retainedAuths.append(auth)
        return auth
    }

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        retainedAuths = []
        keychainAccounts.forEach { _ = KeychainStore.delete(service: testService, account: $0) }
        keychainAccounts = []
        super.tearDown()
    }

    /// Verifies the dual load populates the grouped browse and the flat lookup,
    /// and that `customFood(for:)` resolves a known portion id while missing ids
    /// return nil.
    func test_load_populatesBrowseAndPortionLookup() async throws {
        let model = FoodsModel(auth: try makeAuth())
        await model.load()
        guard case .loaded(let browse) = model.state else {
            return XCTFail("expected loaded, got \(model.state)")
        }
        XCTAssertEqual(browse.foods.count, 1)
        XCTAssertEqual(browse.standalones.count, 1)
        let shakeId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        XCTAssertEqual(model.customFood(for: shakeId)?.name, "Protein Shake")
        XCTAssertNil(model.customFood(for: UUID()))
    }

    /// Locks the documented invariant that a flat custom-food list failure does
    /// not by itself fail the browse: with `/foods` succeeding and
    /// `/custom-foods` returning HTTP 500, `state` still lands on `.loaded`
    /// (foods present) while `customFoodsById` stays empty.
    func test_load_tolerablesFlatListFailure() async throws {
        let model = FoodsModel(auth: try makeAuth(foodsStatus: 200, customFoodsStatus: 500))
        await model.load()
        guard case .loaded(let browse) = model.state else {
            return XCTFail("expected loaded, got \(model.state)")
        }
        XCTAssertEqual(browse.foods.count, 1)
        XCTAssertTrue(model.customFoodsById.isEmpty)
    }
}
