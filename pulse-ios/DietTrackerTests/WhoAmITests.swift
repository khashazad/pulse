import XCTest
@testable import DietTracker

final class WhoAmITests: XCTestCase {
    func testDecodesFromFixture() throws {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: "whoami", withExtension: "json")!
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder.dietTrackerDefault()
        let result = try decoder.decode(WhoAmI.self, from: data)
        XCTAssertEqual(result.email, "khashzd@gmail.com")
        XCTAssertEqual(
            result.expiresAt.timeIntervalSince1970,
            ISO8601DateFormatter().date(from: "2026-08-07T12:00:00Z")!.timeIntervalSince1970,
            accuracy: 1
        )
    }
}
