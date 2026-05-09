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
