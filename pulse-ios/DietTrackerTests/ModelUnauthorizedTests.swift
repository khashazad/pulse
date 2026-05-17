/// Integration-style tests for the auth-aware view models.
/// Verifies that a screen view model (e.g. `DayMacroModel`) which receives
/// a 401 from the backend forces its owning `AuthSession` to sign out and
/// clear the keychain, so the next launch lands on the sign-in screen.
/// Part of the iOS app's auth-integration test suite.
import XCTest
@testable import DietTracker

final class ModelUnauthorizedTests: XCTestCase {
    private let testService = "com.khxsh.diettracker.session.test"
    private let testAccount = "model-unauth-\(UUID().uuidString)"

    /// Writes a JSON-encoded session blob to the test keychain slot.
    /// Inputs:
    ///   - token: bearer token value to embed.
    ///   - email: account email to embed.
    private func writeStoredSession(token: String, email: String) {
        let json = #"{"token":"\#(token)","email":"\#(email)"}"#
        _ = KeychainStore.write(json, service: testService, account: testAccount)
    }

    /// Builds an ephemeral `URLSession` wired to `StubURLProtocol`.
    /// Outputs: a fresh `URLSession` for stubbed HTTP traffic.
    private func makeStubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    /// Removes the test keychain entry after each test.
    override func tearDown() {
        _ = KeychainStore.delete(service: testService, account: testAccount)
        super.tearDown()
    }

    /// Verifies that loading `DayMacroModel` against a 401-returning server
    /// puts the model into `.failed(.unauthorized)` AND signs out the
    /// `AuthSession`, clearing the keychain.
    func testDayMacroModel401SignsOutAuthSession() async {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: makeStubSession()
        )
        XCTAssertTrue(auth.isSignedIn)

        let model = DayMacroModel(date: Date(), auth: auth)
        await model.load()

        // The model's load failed with .unauthorized AND AuthSession transitioned to signed-out.
        if case .failed(let err) = model.state {
            XCTAssertEqual(err, .unauthorized)
        } else {
            XCTFail("Expected .failed(.unauthorized); got \(model.state)")
        }
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(KeychainStore.read(service: testService, account: testAccount))
        StubURLProtocol.responder = nil
    }
}
