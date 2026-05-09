import XCTest
@testable import DietTracker

final class AuthSessionTests: XCTestCase {
    private let testService = "com.khxsh.diettracker.session.test"
    private let testAccount = "auth-test-\(UUID().uuidString)"

    private func writeStoredSession(token: String, email: String) {
        let json = #"{"token":"\#(token)","email":"\#(email)"}"#
        _ = KeychainStore.write(json, service: testService, account: testAccount)
    }

    private func clearStoredSession() {
        _ = KeychainStore.delete(service: testService, account: testAccount)
    }

    override func tearDown() {
        clearStoredSession()
        super.tearDown()
    }

    func testInitWithStoredSessionStartsSignedIn() {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(auth.email, "khashzd@gmail.com")
    }

    func testInitWithNoStoredSessionStartsSignedOut() {
        clearStoredSession()
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(auth.email)
    }

    func testInitWithCorruptedKeychainBlobStartsSignedOut() {
        _ = KeychainStore.write("not-json", service: testService, account: testAccount)
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        XCTAssertFalse(auth.isSignedIn)
    }
}

extension AuthSessionTests {
    func testHandleCallbackSuccessSignsInAndPersists() {
        clearStoredSession()
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        auth.handleSignInCallback(url: URL(string: "diettracker://auth?token=t1&email=khashzd%40gmail.com")!)
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(auth.email, "khashzd@gmail.com")
        // Persisted across a fresh AuthSession?
        let fresh = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        XCTAssertTrue(fresh.isSignedIn)
        XCTAssertEqual(fresh.email, "khashzd@gmail.com")
    }

    func testHandleCallbackErrorTransitionsToError() {
        clearStoredSession()
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        auth.handleSignInCallback(url: URL(string: "diettracker://auth?error=not_allowed")!)
        if case .error(let e) = auth.state {
            XCTAssertEqual(e, .signInFailed(reason: "not_allowed"))
        } else {
            XCTFail("Expected .error state, got \(auth.state)")
        }
        XCTAssertFalse(auth.isSignedIn)
    }
}

extension AuthSessionTests {
    private func makeStubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    func testBootstrapHappyPathStaysSignedIn() async {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        StubURLProtocol.responder = { req in
            let body = #"{"email":"khashzd@gmail.com","expires_at":"2026-08-07T12:00:00Z"}"#
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body.data(using: .utf8)!)
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: makeStubSession()
        )
        await auth.bootstrap()
        XCTAssertTrue(auth.isSignedIn)
        StubURLProtocol.responder = nil
    }

    func testBootstrap401SignsOutAndClearsKeychain() async {
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
        await auth.bootstrap()
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(KeychainStore.read(service: testService, account: testAccount))
        StubURLProtocol.responder = nil
    }

    func testBootstrapNetworkErrorKeepsOptimisticSignedIn() async {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        StubURLProtocol.responder = { _ in
            // 500 is a non-401 error that bootstrap should ignore (offline-grace).
            let resp = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: makeStubSession()
        )
        await auth.bootstrap()
        XCTAssertTrue(auth.isSignedIn)
        StubURLProtocol.responder = nil
    }

    func testBootstrapWithNoStoredTokenIsNoOp() async {
        clearStoredSession()
        var hit = false
        StubURLProtocol.responder = { req in
            hit = true
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: makeStubSession()
        )
        await auth.bootstrap()
        XCTAssertFalse(hit)
        XCTAssertFalse(auth.isSignedIn)
        StubURLProtocol.responder = nil
    }
}

extension AuthSessionTests {
    func testSignOutClearsLocalStateOn204() async {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: makeStubSession()
        )
        await auth.signOut()
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(KeychainStore.read(service: testService, account: testAccount))
        StubURLProtocol.responder = nil
    }

    func testSignOutClearsLocalStateOnServerError() async {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: makeStubSession()
        )
        await auth.signOut()
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(KeychainStore.read(service: testService, account: testAccount))
        StubURLProtocol.responder = nil
    }
}

extension AuthSessionTests {
    func testMakeClientNilWhenSignedOut() {
        clearStoredSession()
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        XCTAssertNil(auth.makeClient())
    }

    func testMakeClientNonNilWhenSignedIn() {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        XCTAssertNotNil(auth.makeClient())
    }

    func testStartSignInURLBuildsCorrectly() {
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        let url = auth.startSignInURL()
        XCTAssertEqual(url.absoluteString, "https://example.test/auth/google/start")
    }
}
