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
    /// Monday-first gregorian calendar, matching `PeriodIntakeModel.weekCalendar`.
    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Toronto")!
        c.firstWeekday = 2 // Monday
        return c
    }

    private func log(_ date: Date, kcal: Int, entries: Int = 1) -> DailyLog {
        DailyLog(date: date, totalCalories: kcal, totalProteinG: 0, totalCarbsG: 0,
                 totalFatG: 0, entryCount: entries)
    }

    private func day(_ d: Int) -> Date {
        cal().date(from: DateComponents(year: 2026, month: 5, day: d))!
    }

    /// Each week renders a full Monday→Sunday grid: complete past weeks show 7 days,
    /// the current week is capped at today, unlogged days are zero-entry placeholders,
    /// future days are dropped, and aggregates skip the placeholders.
    func test_weeklyLogGroups_fillsMondayToSundayCappedAtToday() {
        // In May 2026, the 18th is a Monday; today is Wed the 20th.
        let today = day(20)
        let groups = PeriodIntakeModel.weeklyLogGroups(
            [
                log(day(19), kcal: 2100), // Tue, current week
                log(day(6), kcal: 1000),  // Wed, earlier week
                log(day(18), kcal: 2000), // Mon, current week
                log(day(21), kcal: 9999) // Thu — future, must be dropped
            ],
            today: today, calendar: cal()
        )
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.label), ["Week 1", "Week 2"])
        XCTAssertFalse(groups[0].isCurrent)
        XCTAssertTrue(groups[1].isCurrent)

        // Earlier week (May 4–10): full Monday→Sunday grid, only May 6 logged.
        XCTAssertEqual(groups[0].days.map(\.date), (4...10).map(day))
        XCTAssertEqual(groups[0].days.filter { $0.entryCount > 0 }.map(\.date), [day(6)])
        XCTAssertEqual(groups[0].avgKcal, 1000) // placeholders skipped

        // Current week: Mon 18 → today (Wed 20); Thu 21 future log excluded.
        XCTAssertEqual(groups[1].days.map(\.date), [day(18), day(19), day(20)])
        XCTAssertEqual(groups[1].days.last?.entryCount, 0) // May 20 unlogged placeholder
        XCTAssertEqual(groups[1].avgKcal, 2050) // avg of 2000 & 2100, placeholder skipped
    }

    /// Empty input yields no groups.
    func test_weeklyLogGroups_emptyInputYieldsNoGroups() {
        XCTAssertTrue(PeriodIntakeModel.weeklyLogGroups([]).isEmpty)
    }
}
