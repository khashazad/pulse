/// Unit tests for the `WeightAnalytics.compute` pipeline.
/// Verifies the maintenance-calorie regression's behavior on insufficient
/// data, on a clean alternating-deficit/surplus signal, on a gap in recent
/// kcal logging, and the trend / ETA branches (stable, trending away, no
/// target). Trend reporting must be independent of kcal availability.
/// Part of the iOS app's analytics test suite.
import XCTest
@testable import DietTracker

final class WeightAnalyticsTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private let today: Date = {
        let cal = Calendar(identifier: .gregorian)
        return cal.date(from: DateComponents(year: 2026, month: 5, day: 13))!
    }()

    /// Returns the date that is `n` days from the fixed `today` anchor.
    /// Inputs:
    ///   - n: signed day offset.
    /// Outputs: the offset `Date`.
    private func dayOffset(_ n: Int) -> Date {
        cal.date(byAdding: .day, value: n, to: today)!
    }

    /// Builds a `WeightEntry` at the given offset with the given lb weight.
    /// Inputs:
    ///   - offset: signed day offset from `today`.
    ///   - lb: weight in pounds.
    /// Outputs: a `WeightEntry`.
    private func entry(_ offset: Int, lb: Double) -> WeightEntry {
        WeightEntry(
            id: UUID(),
            date: dayOffset(offset),
            weightLb: lb,
            sourceUnit: .lb,
            createdAt: today,
            updatedAt: today
        )
    }

    /// Builds a daily-calories row at the given offset with the given total.
    /// Inputs:
    ///   - offset: signed day offset from `today`.
    ///   - c: kcal total for that day.
    /// Outputs: a `CaloriesDailyRow`.
    private func kcal(_ offset: Int, _ c: Int) -> CaloriesDailyRow {
        CaloriesDailyRow(date: dayOffset(offset), calories: c)
    }

    /// Verifies that with too few data points, maintenance and recent
    /// window are nil.
    func testInsufficientData() {
        let result = WeightAnalytics.compute(
            entries: [entry(-2, lb: 180), entry(-1, lb: 179.5)],
            kcal: [kcal(-2, 2000), kcal(-1, 2000)],
            targetWeightLb: 170,
            today: today
        )
        XCTAssertNil(result.maintenanceKcal)
        XCTAssertNil(result.recentWindowDays)
    }

    /// Verifies the regression recovers the synthesized true maintenance
    /// kcal within tolerance from a clean alternating signal.
    func testSimpleMaintenanceRecovers() {
        // 30 days of consecutive logs alternating 1800/2400 kcal, weights
        // matching (c-2500)/3500 lb/day so true maintenance = 2500.
        var entries: [WeightEntry] = []
        var kcalRows: [CaloriesDailyRow] = []
        var weight = 200.0
        for d in stride(from: -29, through: 0, by: 1) {
            let c = (d % 2 == 0) ? 1800 : 2400
            kcalRows.append(kcal(d, c))
            let ratePerDay = Double(c - 2500) / 3500.0
            weight += ratePerDay
            entries.append(entry(d, lb: weight))
        }
        let result = WeightAnalytics.compute(
            entries: entries, kcal: kcalRows, targetWeightLb: 180, today: today
        )
        XCTAssertNotNil(result.maintenanceKcal)
        XCTAssertEqual(result.maintenanceKcal ?? 0, 2500, accuracy: 150)
    }

    /// Verifies a gap in recent kcal logging that drops the run below the
    /// minimum recent-window threshold disables maintenance reporting.
    func testMaintenanceSkippedOnKcalGap() {
        // Recent logging stops short of `minRecentWindowDays` due to a gap.
        var entries: [WeightEntry] = []
        var kcalRows: [CaloriesDailyRow] = []
        for d in stride(from: -29, through: 0, by: 1) {
            entries.append(entry(d, lb: 180.0))
            if d > -5 || d < -10 {  // a gap days -10..-5 → recent run is only 5d
                kcalRows.append(kcal(d, 2000))
            }
        }
        let result = WeightAnalytics.compute(
            entries: entries, kcal: kcalRows, targetWeightLb: 170, today: today
        )
        XCTAssertNil(result.maintenanceKcal)
        XCTAssertNil(result.recentWindowDays)
    }

    /// Verifies trend and ETA are computed from weight data even when no
    /// kcal data is available.
    func testTrendIndependentOfKcalGap() {
        // No kcal logging at all, but plenty of recent weight data → trend
        // and ETA must still be reported.
        var entries: [WeightEntry] = []
        for d in stride(from: -27, through: 0, by: 1) {
            entries.append(entry(d, lb: 180.0 - Double(28 + d) * 0.07))
        }
        let result = WeightAnalytics.compute(
            entries: entries, kcal: [], targetWeightLb: 170, today: today
        )
        XCTAssertNotNil(result.trendLbPerWeek)
        XCTAssertNotNil(result.etaToTarget)
        XCTAssertNil(result.maintenanceKcal)
    }

    /// Verifies a flat weight series with steady kcal reports `.stable` ETA.
    func testStableTrendETA() {
        var entries: [WeightEntry] = []
        for d in stride(from: -29, through: 0, by: 1) {
            entries.append(entry(d, lb: 180.0))
        }
        let result = WeightAnalytics.compute(
            entries: entries,
            kcal: (-29...0).map { kcal($0, 2000) },
            targetWeightLb: 170,
            today: today
        )
        XCTAssertEqual(result.etaToTarget, .stable)
    }

    /// Verifies a weight trend moving away from the target reports `.never`
    /// as the ETA.
    func testTrendingAwayETA() {
        var entries: [WeightEntry] = []
        for d in stride(from: -29, through: 0, by: 1) {
            entries.append(entry(d, lb: 180.0 + Double(30 + d) * 0.1))
        }
        let result = WeightAnalytics.compute(
            entries: entries,
            kcal: (-29...0).map { kcal($0, 3000) },
            targetWeightLb: 170,
            today: today
        )
        XCTAssertEqual(result.etaToTarget, .never)
    }

    /// Verifies that with no target weight set, ETA is nil regardless of trend.
    func testNoTargetNoETA() {
        var entries: [WeightEntry] = []
        for d in stride(from: -29, through: 0, by: 1) {
            entries.append(entry(d, lb: 180.0 - Double(30 + d) * 0.05))
        }
        let result = WeightAnalytics.compute(
            entries: entries,
            kcal: (-29...0).map { kcal($0, 1800) },
            targetWeightLb: nil,
            today: today
        )
        XCTAssertNil(result.etaToTarget)
    }
}
