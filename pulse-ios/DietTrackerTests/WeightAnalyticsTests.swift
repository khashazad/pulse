import XCTest
@testable import DietTracker

final class WeightAnalyticsTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private let today: Date = {
        let cal = Calendar(identifier: .gregorian)
        return cal.date(from: DateComponents(year: 2026, month: 5, day: 13))!
    }()

    private func dayOffset(_ n: Int) -> Date {
        cal.date(byAdding: .day, value: n, to: today)!
    }

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

    private func kcal(_ offset: Int, _ c: Int) -> CaloriesDailyRow {
        CaloriesDailyRow(date: dayOffset(offset), calories: c)
    }

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
