// PulseTests/DayExclusionAveragesTests.swift
import XCTest
@testable import Pulse

/// Unit tests for the day-exclusion effect on period averages: `DailyLog`
/// averages must skip both empty days and days flagged `excluded`, and the
/// `excluded` wire field must default to `false` when absent from JSON so
/// older cached payloads still decode.
final class DayExclusionAveragesTests: XCTestCase {
    /// Builds a `DailyLog` for a day offset from a fixed anchor.
    private func log(dayOffset: Int, kcal: Int, entries: Int = 3, excluded: Bool = false) -> DailyLog {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: anchor)!
        return DailyLog(
            date: date, totalCalories: kcal,
            totalProteinG: Double(kcal) / 10, totalCarbsG: Double(kcal) / 8,
            totalFatG: Double(kcal) / 20, entryCount: entries, excluded: excluded
        )
    }

    func test_avgCalories_skipsExcludedDays() {
        // Two counted days (2000, 2000) + one excluded low day that would drag
        // the mean down if included.
        let logs = [
            log(dayOffset: 0, kcal: 2000),
            log(dayOffset: 1, kcal: 2000),
            log(dayOffset: 2, kcal: 200, excluded: true)
        ]
        XCTAssertEqual(logs.avgCalories, 2000, "excluded day must not affect the mean")
        XCTAssertEqual(logs.statDays.count, 2)
    }

    func test_avgCalories_skipsEmptyDays() {
        let logs = [
            log(dayOffset: 0, kcal: 1800),
            log(dayOffset: 1, kcal: 0, entries: 0)
        ]
        XCTAssertEqual(logs.avgCalories, 1800, "empty day (0 entries) is not counted")
    }

    func test_averages_zeroWhenAllDaysExcludedOrEmpty() {
        let logs = [
            log(dayOffset: 0, kcal: 2000, excluded: true),
            log(dayOffset: 1, kcal: 0, entries: 0)
        ]
        XCTAssertEqual(logs.avgCalories, 0)
        XCTAssertEqual(logs.avgProtein, 0)
        XCTAssertEqual(logs.avgCarbs, 0)
        XCTAssertEqual(logs.avgFat, 0)
    }

    func test_dailyLog_decodesMissingExcludedAsFalse() throws {
        // Payload without the excluded key (a pre-feature cached response).
        let json = """
        {"date":"2026-05-06","total_calories":1800,"total_protein_g":120.0,
         "total_carbs_g":180.0,"total_fat_g":60.0,"entry_count":5}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder.pulseDefault().decode(DailyLog.self, from: json)
        XCTAssertFalse(decoded.excluded)
    }

    func test_dailyLog_decodesExcludedTrue() throws {
        let json = """
        {"date":"2026-05-06","total_calories":1800,"total_protein_g":120.0,
         "total_carbs_g":180.0,"total_fat_g":60.0,"entry_count":5,"excluded":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder.pulseDefault().decode(DailyLog.self, from: json)
        XCTAssertTrue(decoded.excluded)
    }
}
