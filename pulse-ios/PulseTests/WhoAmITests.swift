/// Unit tests for `WhoAmI` decoding.
/// Confirms the `/auth/whoami` response fixture decodes email and ISO-8601
/// `expires_at` correctly via the shared `pulseDefault()` decoder.
/// Part of the iOS app's auth-layer test suite.
import XCTest
@testable import Pulse

final class WhoAmITests: XCTestCase {
    /// Verifies the fixture decodes with the expected email and that
    /// `expiresAt` matches the embedded ISO-8601 timestamp within one second.
    func testDecodesFromFixture() throws {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: "whoami", withExtension: "json")!
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder.pulseDefault()
        let result = try decoder.decode(WhoAmI.self, from: data)
        XCTAssertEqual(result.email, "khashzd@gmail.com")
        XCTAssertEqual(
            result.expiresAt.timeIntervalSince1970,
            ISO8601DateFormatter().date(from: "2026-08-07T12:00:00Z")!.timeIntervalSince1970,
            accuracy: 1
        )
    }
}
