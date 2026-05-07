import XCTest
@testable import Nutrition

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
        let summary = try JSONDecoder.nutritionDefault().decode(DailySummary.self, from: data)

        XCTAssertEqual(summary.target.calories, 2200)
        XCTAssertEqual(summary.consumed.calories, 740)
        XCTAssertEqual(summary.remaining.calories, 1460)
        XCTAssertEqual(summary.entries.count, 3)

        let oats = summary.entries[0]
        XCTAssertEqual(oats.displayName, "Oats, raw")
        XCTAssertEqual(oats.calories, 320)
        XCTAssertEqual(oats.proteinG, 10.0)
        XCTAssertEqual(oats.usdaFdcId, 173904)
        XCTAssertNil(oats.customFoodId)

        let chicken = summary.entries[2]
        XCTAssertNil(chicken.usdaFdcId)
        XCTAssertEqual(chicken.customFoodId?.uuidString, "88888888-8888-8888-8888-888888888888")
    }

    func testDecodeLogsList() throws {
        let data = try loadFixture("logs")
        let list = try JSONDecoder.nutritionDefault().decode(LogsList.self, from: data)

        XCTAssertEqual(list.logs.count, 7)
        XCTAssertEqual(list.logs[0].totalCalories, 740)
        XCTAssertEqual(list.logs[0].entryCount, 3)
        XCTAssertEqual(list.logs[6].totalCalories, 2300)
    }

    func testSummaryDateIsParsedAsCalendarDate() throws {
        let data = try loadFixture("summary")
        let summary = try JSONDecoder.nutritionDefault().decode(DailySummary.self, from: data)
        let str = DateOnly.string(from: summary.date)
        XCTAssertEqual(str, "2026-05-06")
    }
}
