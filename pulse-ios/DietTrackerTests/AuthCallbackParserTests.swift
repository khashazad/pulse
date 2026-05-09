import XCTest
@testable import DietTracker

final class AuthCallbackParserTests: XCTestCase {
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

    func testNotAllowedError() {
        let url = URL(string: "diettracker://auth?error=not_allowed")!
        switch AuthCallbackParser.parse(url) {
        case .success: XCTFail("Expected failure")
        case .failure(let e): XCTAssertEqual(e, .signInFailed(reason: "not_allowed"))
        }
    }

    func testAccessDeniedError() {
        let url = URL(string: "diettracker://auth?error=access_denied")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "access_denied"))
        } else { XCTFail() }
    }

    func testInvalidStateError() {
        let url = URL(string: "diettracker://auth?error=invalid_state")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "invalid_state"))
        } else { XCTFail() }
    }

    func testServerError() {
        let url = URL(string: "diettracker://auth?error=server_error")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "server_error"))
        } else { XCTFail() }
    }

    func testMissingTokenIsInvalidCallback() {
        let url = URL(string: "diettracker://auth?email=foo%40bar.com")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "invalid_callback"))
        } else { XCTFail() }
    }

    func testMissingEmailIsInvalidCallback() {
        let url = URL(string: "diettracker://auth?token=abc")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "invalid_callback"))
        } else { XCTFail() }
    }

    func testEmptyQueryIsInvalidCallback() {
        let url = URL(string: "diettracker://auth")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "invalid_callback"))
        } else { XCTFail() }
    }
}
