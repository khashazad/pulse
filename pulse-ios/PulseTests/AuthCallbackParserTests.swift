/// Unit tests for `AuthCallbackParser`.
/// Verifies the parser extracts the one-time exchange `code` from a successful
/// OAuth callback URL and maps each documented `error=` value to the matching
/// `signInFailed` reason, including the catch-all `invalid_callback` case when
/// the code is missing.
/// Part of the iOS app's auth-layer test suite.
import XCTest
@testable import Pulse

final class AuthCallbackParserTests: XCTestCase {
    /// Verifies a callback with a `code` query item decodes into that code.
    func testParsesCode() {
        let url = URL(string: "diettracker://auth?code=one-time-abc123")!
        switch AuthCallbackParser.parse(url) {
        case .success(let code):
            XCTAssertEqual(code, "one-time-abc123")
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

    /// Verifies `error=invalid_request` (missing PKCE) parses into a failure reason.
    func testInvalidRequestError() {
        let url = URL(string: "diettracker://auth?error=invalid_request")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "invalid_request"))
        } else { XCTFail() }
    }

    /// Verifies `error=server_error` parses into the matching failure reason.
    func testServerError() {
        let url = URL(string: "diettracker://auth?error=server_error")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "server_error"))
        } else { XCTFail() }
    }

    /// Verifies a callback missing the `code` query item maps to `invalid_callback`.
    func testMissingCodeIsInvalidCallback() {
        let url = URL(string: "diettracker://auth?foo=bar")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "invalid_callback"))
        } else { XCTFail() }
    }

    /// Verifies an empty `code` query item maps to `invalid_callback`.
    func testEmptyCodeIsInvalidCallback() {
        let url = URL(string: "diettracker://auth?code=")!
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
