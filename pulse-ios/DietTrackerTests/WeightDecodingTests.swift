/// Unit tests for `WeightEntry` and `CaloriesDailyRow` decoding.
/// Confirms weights round-trip through `dietTrackerDefault()` with their
/// `sourceUnit` preserved, and that the daily-calories rows decode in order.
/// Part of the iOS app's decoding test suite.
import XCTest
@testable import DietTracker

final class WeightDecodingTests: XCTestCase {

    /// Loads a JSON fixture from the test bundle.
    /// Inputs:
    ///   - name: fixture file base name.
    /// Outputs: raw bytes of `<name>.json`.
    /// Exceptions: throws if the fixture is missing or unreadable.
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")!
        return try Data(contentsOf: url)
    }

    /// Verifies the `weight_entries` fixture decodes with the right count
    /// and per-entry `sourceUnit`.
    func testDecodeWeightEntries() throws {
        let data = try fixture("weight_entries")
        let entries = try JSONDecoder.dietTrackerDefault().decode([WeightEntry].self, from: data)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].weightLb, 180.50, accuracy: 0.001)
        XCTAssertEqual(entries[0].sourceUnit, .lb)
        XCTAssertEqual(entries[1].sourceUnit, .kg)
    }

    /// Verifies the `calories_daily` fixture decodes with correct ordering
    /// and per-row totals.
    func testDecodeCaloriesDaily() throws {
        let data = try fixture("calories_daily")
        let rows = try JSONDecoder.dietTrackerDefault().decode([CaloriesDailyRow].self, from: data)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1].calories, 2100)
    }
}
