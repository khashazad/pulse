/// Unit tests for `AuthSession`.
/// Covers initial state recovery from the keychain, sign-in callback
/// handling, bootstrap behavior against `/auth/whoami` (200 / 401 / network
/// error), sign-out cleanup, and the `makeClient` / `startSignInURL`
/// convenience methods. Uses `StubURLProtocol` to fake HTTP responses and a
/// dedicated test-only keychain account so runs do not collide with the
/// app's real session.
/// Part of the iOS app's auth-layer test suite.
import XCTest
@testable import DietTracker

final class AuthSessionTests: XCTestCase {
    private let testService = "com.khxsh.diettracker.session.test"
    private let testAccount = "auth-test-\(UUID().uuidString)"
    private var activeStubs: [StubURLProtocol.Registration] = []

    /// Writes a JSON-encoded session blob to the test keychain slot.
    /// Inputs:
    ///   - token: Bearer token value to embed.
    ///   - email: Account email to embed.
    private func writeStoredSession(token: String, email: String) {
        let json = #"{"token":"\#(token)","email":"\#(email)"}"#
        _ = KeychainStore.write(json, service: testService, account: testAccount)
    }

    /// Deletes any stored session blob from the test keychain slot.
    private func clearStoredSession() {
        _ = KeychainStore.delete(service: testService, account: testAccount)
    }

    /// Clears the test keychain slot after each test.
    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        clearStoredSession()
        super.tearDown()
    }

    /// Verifies a stored session blob causes `AuthSession.init` to come up
    /// signed in with the persisted email exposed.
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

    /// Verifies init with an empty keychain leaves the session signed out
    /// and `email` nil.
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

    /// Verifies init with a non-JSON keychain blob is treated as no session
    /// rather than crashing.
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
    /// Verifies a successful sign-in callback URL transitions the session to
    /// signed-in and persists the credentials so a fresh `AuthSession`
    /// instance reading the same keychain slot also comes up signed-in.
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

    /// Verifies an `error=` callback URL moves the session into the `.error`
    /// state with the right reason and leaves the user signed out.
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
    /// Builds an ephemeral `URLSession` wired to a scoped `StubURLProtocol` responder.
    /// Inputs:
    ///   - responder: closure that returns a stubbed HTTP response.
    /// Outputs: a fresh `URLSession` configured for stubbed requests.
    private func makeStubSession(responder: @escaping StubURLProtocol.Responder) -> URLSession {
        let stub = StubURLProtocol.makeSession(responder: responder)
        activeStubs.append(stub)
        return stub.session
    }

    /// Verifies a 200 response from `/auth/whoami` during bootstrap keeps
    /// the session signed in.
    func testBootstrapHappyPathStaysSignedIn() async {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        let session = makeStubSession { req in
            let body = #"{"email":"khashzd@gmail.com","expires_at":"2026-08-07T12:00:00Z"}"#
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body.data(using: .utf8)!)
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: session
        )
        await auth.bootstrap()
        XCTAssertTrue(auth.isSignedIn)
    }

    /// Verifies a 401 from `/auth/whoami` during bootstrap forces sign-out
    /// and removes the persisted credentials.
    func testBootstrap401SignsOutAndClearsKeychain() async {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        let session = makeStubSession { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: session
        )
        await auth.bootstrap()
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(KeychainStore.read(service: testService, account: testAccount))
    }

    /// Verifies a non-401 server error during bootstrap leaves the
    /// optimistic signed-in state intact (offline grace).
    func testBootstrapNetworkErrorKeepsOptimisticSignedIn() async {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        let session = makeStubSession { _ in
            // 500 is a non-401 error that bootstrap should ignore (offline-grace).
            let resp = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: session
        )
        await auth.bootstrap()
        XCTAssertTrue(auth.isSignedIn)
    }

    /// Verifies bootstrap performs no HTTP work when there is no stored
    /// session, and the session remains signed out.
    func testBootstrapWithNoStoredTokenIsNoOp() async {
        clearStoredSession()
        var hit = false
        let session = makeStubSession { req in
            hit = true
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: session
        )
        await auth.bootstrap()
        XCTAssertFalse(hit)
        XCTAssertFalse(auth.isSignedIn)
    }
}

extension AuthSessionTests {
    /// Verifies a successful (204) sign-out call clears in-memory state and
    /// removes the keychain entry.
    func testSignOutClearsLocalStateOn204() async {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        let session = makeStubSession { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: session
        )
        await auth.signOut()
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(KeychainStore.read(service: testService, account: testAccount))
    }

    /// Verifies sign-out still clears local state and keychain even when
    /// the server responds with 500.
    func testSignOutClearsLocalStateOnServerError() async {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        let session = makeStubSession { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: session
        )
        await auth.signOut()
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(KeychainStore.read(service: testService, account: testAccount))
    }
}

extension AuthSessionTests {
    /// Verifies `makeClient()` returns nil while the session is signed out.
    func testMakeClientNilWhenSignedOut() {
        clearStoredSession()
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        XCTAssertNil(auth.makeClient())
    }

    /// Verifies `makeClient()` returns a non-nil `DietTrackerClient` once a
    /// session is restored from the keychain.
    func testMakeClientNonNilWhenSignedIn() {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        XCTAssertNotNil(auth.makeClient())
    }

    /// Verifies `startSignInURL()` resolves to `/auth/google/start` on the
    /// configured base URL.
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
