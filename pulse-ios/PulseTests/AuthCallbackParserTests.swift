/// Unit tests for `AuthCallbackParser`.
/// Verifies the parser extracts token/email from a successful OAuth callback
/// URL and maps each documented `error=` value to the matching `signInFailed`
/// reason, including the catch-all `invalid_callback` case when required
/// parameters are missing.
/// Part of the iOS app's auth-layer test suite.
import XCTest
@testable import Pulse

final class AuthCallbackParserTests: XCTestCase {
    /// Verifies a callback with both token and email query items decodes into
    /// credentials whose fields are URL-decoded correctly.
    func testParsesTokenAndEmail() {
        let url = URL(string: "diettracker://auth?token=abc123&email=khashzd%40gmail.com")!
        switch AuthCallbackParser.parse(url) {
        case .success(let creds):
            XCTAssertEqual(creds.token, "abc123")
            XCTAssertEqual(creds.email, "khashzd@gmail.com")
        case .failure(let e):
            XCTFail("Expected success, got \(e)")
        }
    }

    /// Verifies `error=not_allowed` parses into the matching failure reason.
    func testNotAllowedError() {
        let url = URL(string: "diettracker://auth?error=not_allowed")!
        switch AuthCallbackParser.parse(url) {
        case .success: XCTFail("Expected failure")
        case .failure(let e): XCTAssertEqual(e, .signInFailed(reason: "not_allowed"))
        }
    }

    /// Verifies `error=access_denied` parses into the matching failure reason.
    func testAccessDeniedError() {
        let url = URL(string: "diettracker://auth?error=access_denied")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "access_denied"))
        } else { XCTFail() }
    }

    /// Verifies `error=invalid_state` parses into the matching failure reason.
    func testInvalidStateError() {
        let url = URL(string: "diettracker://auth?error=invalid_state")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "invalid_state"))
        } else { XCTFail() }
    }

    /// Verifies `error=server_error` parses into the matching failure reason.
    func testServerError() {
        let url = URL(string: "diettracker://auth?error=server_error")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "server_error"))
        } else { XCTFail() }
    }

    /// Verifies a callback missing the token query item maps to `invalid_callback`.
    func testMissingTokenIsInvalidCallback() {
        let url = URL(string: "diettracker://auth?email=foo%40bar.com")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "invalid_callback"))
        } else { XCTFail() }
    }

    /// Verifies a callback missing the email query item maps to `invalid_callback`.
    func testMissingEmailIsInvalidCallback() {
        let url = URL(string: "diettracker://auth?token=abc")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "invalid_callback"))
        } else { XCTFail() }
    }

    /// Verifies a callback with no query string at all maps to `invalid_callback`.
    func testEmptyQueryIsInvalidCallback() {
        let url = URL(string: "diettracker://auth")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "invalid_callback"))
        } else { XCTFail() }
    }
}
