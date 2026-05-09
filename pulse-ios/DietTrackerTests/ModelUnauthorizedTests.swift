import XCTest
@testable import DietTracker

final class ModelUnauthorizedTests: XCTestCase {
    private let testService = "com.khxsh.diettracker.session.test"
    private let testAccount = "model-unauth-\(UUID().uuidString)"

    private func writeStoredSession(token: String, email: String) {
        let json = #"{"token":"\#(token)","email":"\#(email)"}"#
        _ = KeychainStore.write(json, service: testService, account: testAccount)
    }

    private func makeStubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override func tearDown() {
        _ = KeychainStore.delete(service: testService, account: testAccount)
        super.tearDown()
    }

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
