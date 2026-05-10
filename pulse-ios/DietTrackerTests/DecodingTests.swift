import XCTest
@testable import DietTracker

final class DecodingTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("Fixture \(name).json not found in test bundle")
            throw NSError(domain: "fixture", code: 0)
        }
        return try Data(contentsOf: url)
    }

    func testDecodeDailySummary() throws {
        let data = try loadFixture("summary")
        let summary = try JSONDecoder.dietTrackerDefault().decode(DailySummary.self, from: data)

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

    func testDecodeLogsList() throws {
        let data = try loadFixture("logs")
        let list = try JSONDecoder.dietTrackerDefault().decode(LogsList.self, from: data)

        XCTAssertEqual(list.logs.count, 7)
        XCTAssertEqual(list.logs[0].totalCalories, 740)
        XCTAssertEqual(list.logs[0].entryCount, 3)
        XCTAssertEqual(list.logs[6].totalCalories, 2300)
    }

    func testSummaryDateIsParsedAsCalendarDate() throws {
        let data = try loadFixture("summary")
        let summary = try JSONDecoder.dietTrackerDefault().decode(DailySummary.self, from: data)
        let str = DateOnly.string(from: summary.date)
        XCTAssertEqual(str, "2026-05-06")
    }
}
