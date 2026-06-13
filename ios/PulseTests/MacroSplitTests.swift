// PulseTests/MacroSplitTests.swift
/// Pure-logic tests for the Month view's macro-composition math (`MacroSplit`)
/// and the per-week log grouping (`PeriodIntakeModel.weeklyLogGroups`) that feeds
/// the stacked-segment bar rows. Deterministic; no run-loop or network.
import XCTest
@testable import Pulse

// MARK: - Macro split math

final class MacroSplitTests: XCTestCase {
    /// Builds a `DailyLog` for the given macros on a fixed date.
    /// - Parameters:
    ///   - p: protein grams.
    ///   - c: carbohydrate grams.
    ///   - f: fat grams.
    ///   - kcal: total calories (defaults to the Atwater sum of the macros).
    ///   - date: the log's day instant.
    ///   - entries: entry count (0 marks an unlogged day).
    /// - Returns: a `DailyLog` value.
    private func log(p: Double, c: Double, f: Double, kcal: Int? = nil,
                     date: Date = Date(timeIntervalSince1970: 0), entries: Int = 1) -> DailyLog {
        DailyLog(
            date: date,
            totalCalories: kcal ?? Int((p * 4 + c * 4 + f * 9).rounded()),
            totalProteinG: p, totalCarbsG: c, totalFatG: f, entryCount: entries
        )
    }

    /// Equal protein/carb calories with no fat split 50/50/0.
    func test_macroSplit_evenProteinCarbs() {
        let split = log(p: 100, c: 100, f: 0).macroSplit
        XCTAssertEqual(split, MacroSplit(proteinPct: 50, carbsPct: 50, fatPct: 0))
    }

    /// Fat uses the 9 kcal/g Atwater factor, not gram count: equal grams still make
    /// fat the dominant share. Fat absorbs rounding (derived as 100 − protein − carbs).
    func test_macroSplit_fatWeightedByEnergy() {
        // 10g protein (40), 10g carbs (40), 10g fat (90) of 170 total.
        let split = log(p: 10, c: 10, f: 10).macroSplit
        XCTAssertEqual(split?.proteinPct, 24) // 40/170 = 23.5 → 24
        XCTAssertEqual(split?.carbsPct, 24)
        XCTAssertEqual(split?.fatPct, 52)     // 100 − 24 − 24 (fat is the largest share)
        XCTAssertEqual((split?.proteinPct ?? 0) + (split?.carbsPct ?? 0) + (split?.fatPct ?? 0), 100)
    }

    /// Percentages always sum to exactly 100 even when raw rounding would not.
    func test_macroSplit_alwaysSumsTo100() {
        let split = log(p: 25, c: 25, f: 10).macroSplit // 100/100/90 of 290
        XCTAssertNotNil(split)
        XCTAssertEqual((split!.proteinPct) + (split!.carbsPct) + (split!.fatPct), 100)
    }

    /// A day with no macros has no split (nil), not a divide-by-zero.
    func test_macroSplit_zeroMacrosIsNil() {
        XCTAssertNil(log(p: 0, c: 0, f: 0, kcal: 0, entries: 0).macroSplit)
        XCTAssertNil(log(p: 0, c: 0, f: 0).macroFractions)
    }

    /// Fractions are normalized to sum to 1.
    func test_macroFractions_sumToOne() {
        let f = log(p: 30, c: 40, f: 20).macroFractions
        XCTAssertNotNil(f)
        XCTAssertEqual(f!.protein + f!.carbs + f!.fat, 1, accuracy: 0.0001)
    }

    /// Array aggregate split sums grams across days before splitting.
    func test_arrayMacroSplit_aggregatesAcrossDays() {
        let days = [log(p: 50, c: 0, f: 0), log(p: 0, c: 50, f: 0)] // 200 protein cal + 200 carb cal
        XCTAssertEqual(days.macroSplit, MacroSplit(proteinPct: 50, carbsPct: 50, fatPct: 0))
        XCTAssertNil([DailyLog]().macroSplit)
    }
}

// MARK: - Weekly log grouping

final class WeeklyLogGroupTests: XCTestCase {
    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Toronto")!
        return c
    }

    private func log(_ date: Date, kcal: Int, entries: Int = 1) -> DailyLog {
        DailyLog(date: date, totalCalories: kcal, totalProteinG: 0, totalCarbsG: 0,
                 totalFatG: 0, entryCount: entries)
    }

    /// Groups preserve each week's individual days (sorted ascending), label
    /// sequentially, and mark the week containing `today`.
    func test_weeklyLogGroups_preservesDaysAndMarksCurrent() {
        let c = cal()
        let today = c.date(from: DateComponents(year: 2026, month: 5, day: 20))!
        // Current week: two days (intentionally out of order on input).
        let d19 = c.date(from: DateComponents(year: 2026, month: 5, day: 19))!
        let d18 = c.date(from: DateComponents(year: 2026, month: 5, day: 18))!
        // Earlier week: one day.
        let d6 = c.date(from: DateComponents(year: 2026, month: 5, day: 6))!
        let groups = PeriodIntakeModel.weeklyLogGroups(
            [log(d19, kcal: 2100), log(d6, kcal: 1000), log(d18, kcal: 2000)],
            today: today, calendar: c
        )
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.label), ["Week 1", "Week 2"])
        XCTAssertFalse(groups[0].isCurrent)
        XCTAssertTrue(groups[1].isCurrent)
        // Current week keeps both days, sorted ascending by date.
        XCTAssertEqual(groups[1].days.map(\.date), [d18, d19])
        XCTAssertEqual(groups[1].avgKcal, 2050)
    }

    /// Empty input yields no groups.
    func test_weeklyLogGroups_emptyInputYieldsNoGroups() {
        XCTAssertTrue(PeriodIntakeModel.weeklyLogGroups([]).isEmpty)
    }
}
