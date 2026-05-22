/// Unit tests for the core decoding paths used by Day / Logs screens.
/// Confirms `DailySummary` (with mixed USDA + custom-food entries and meal
/// joins), `LogsList`, and the calendar-date parsing for the summary's
/// `date` field all round-trip through `JSONDecoder.pulseDefault()`.
/// Part of the iOS app's decoding test suite.
import XCTest
@testable import Pulse

final class DecodingTests: XCTestCase {

    /// Loads a JSON fixture from the test bundle.
    /// Inputs:
    ///   - name: fixture file base name.
    /// Outputs: raw bytes of `<name>.json`.
    /// Exceptions: throws if the fixture is missing or unreadable.
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("Fixture \(name).json not found in test bundle")
            throw NSError(domain: "fixture", code: 0)
        }
        return try Data(contentsOf: url)
    }

    /// Verifies `DailySummary` decodes target/consumed/remaining totals and
    /// entries with USDA fdc ids, custom-food ids, optional meal joins, and
    /// entries that omit meal fields entirely.
    func testDecodeDailySummary() throws {
        let data = try loadFixture("summary")
        let summary = try JSONDecoder.pulseDefault().decode(DailySummary.self, from: data)

        XCTAssertEqual(summary.target.calories, 2200)
        XCTAssertEqual(summary.consumed.calories, 1280)
        XCTAssertEqual(summary.remaining.calories, 920)
        XCTAssertEqual(summary.entries.count, 6)

        let oats = summary.entries[0]
        XCTAssertEqual(oats.displayName, "Oats, raw")
        XCTAssertEqual(oats.calories, 320)
        XCTAssertEqual(oats.proteinG, 10.0)
        XCTAssertEqual(oats.usdaFdcId, 173904)
        XCTAssertNil(oats.customFoodId)
        XCTAssertEqual(oats.mealId?.uuidString.lowercased(), "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        XCTAssertEqual(oats.mealName, "Breakfast Bowl")

        let chicken = summary.entries[4]
        XCTAssertNil(chicken.usdaFdcId)
        XCTAssertEqual(chicken.customFoodId?.uuidString.lowercased(), "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        XCTAssertNil(chicken.mealId)
        XCTAssertNil(chicken.mealName)

        // Trailing entry omits meal_* keys entirely; they decode as nil.
        let almond = summary.entries[5]
        XCTAssertNil(almond.mealId)
        XCTAssertNil(almond.mealName)
    }

    /// Verifies `LogsList` decodes per-day totals and entry counts.
    func testDecodeLogsList() throws {
        let data = try loadFixture("logs")
        let list = try JSONDecoder.pulseDefault().decode(LogsList.self, from: data)

        XCTAssertEqual(list.logs.count, 7)
        XCTAssertEqual(list.logs[0].totalCalories, 740)
        XCTAssertEqual(list.logs[0].entryCount, 3)
        XCTAssertEqual(list.logs[6].totalCalories, 2300)
    }

    /// Verifies `summary.date` decodes as a calendar day matching the
    /// `YYYY-MM-DD` string in the fixture.
    func testSummaryDateIsParsedAsCalendarDate() throws {
        let data = try loadFixture("summary")
        let summary = try JSONDecoder.pulseDefault().decode(DailySummary.self, from: data)
        let str = DateOnly.string(from: summary.date)
        XCTAssertEqual(str, "2026-05-06")
    }
}
