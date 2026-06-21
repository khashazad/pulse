/// Unit tests for `WeightFluctuation.compute`.
/// Covers a known daily-weigh-in fixture, gaps that skip windows, the
/// insufficient-data empty result, unit conversion, and window-size
/// monotonicity. Pure math; no I/O.
import XCTest
@testable import Pulse

final class WeightFluctuationTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private let today: Date = {
        let cal = Calendar(identifier: .gregorian)
        return cal.date(from: DateComponents(year: 2026, month: 5, day: 13))!
    }()

    /// Returns the date `n` days from the fixed `today` anchor.
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
        WeightEntry(id: UUID(), date: dayOffset(offset), weightLb: lb,
                    sourceUnit: .lb, createdAt: today, updatedAt: today)
    }

    /// Four consecutive daily weigh-ins; 2-day windows give |consecutive diff|.
    func testTwoDayWindowAveragesConsecutiveDiffs() {
        // weights at offsets -3..0: 200, 202, 201, 203
        let entries = [entry(-3, lb: 200), entry(-2, lb: 202),
                       entry(-1, lb: 201), entry(0, lb: 203)]
        let r = WeightFluctuation.compute(
            entries: entries, windowDays: 2, periodDays: 28, unit: .lb, today: today)
        // Valid 2-day windows end at -2,-1,0: ranges 2,1,2 -> avg 1.666...
        XCTAssertEqual(r.sampleCount, 3)
        XCTAssertEqual(r.average!, (2.0 + 1.0 + 2.0) / 3.0, accuracy: 0.0001)
        XCTAssertEqual(r.min!, 1.0, accuracy: 0.0001)
        XCTAssertEqual(r.max!, 2.0, accuracy: 0.0001)
        XCTAssertEqual(r.series.count, 3)
    }

    /// Windows with fewer than 2 weigh-ins are skipped.
    func testGapsSkipWindows() {
        // entries only at offsets -5 and 0 -> no 2-day window has 2 points.
        let entries = [entry(-5, lb: 200), entry(0, lb: 205)]
        let r = WeightFluctuation.compute(
            entries: entries, windowDays: 2, periodDays: 28, unit: .lb, today: today)
        XCTAssertEqual(r.sampleCount, 0)
        XCTAssertNil(r.average)
        XCTAssertTrue(r.series.isEmpty)
    }

    /// Zero or one entry yields an empty result.
    func testInsufficientDataEmptyResult() {
        let r = WeightFluctuation.compute(
            entries: [entry(0, lb: 200)], windowDays: 3, periodDays: 90, unit: .lb, today: today)
        XCTAssertEqual(r.sampleCount, 0)
        XCTAssertNil(r.average)
        XCTAssertNil(r.min)
        XCTAssertNil(r.max)
        XCTAssertTrue(r.series.isEmpty)
    }

    /// kg average equals the lb average scaled by the lb->kg factor.
    func testUnitConversionScalesFluctuation() {
        let entries = [entry(-3, lb: 200), entry(-2, lb: 202),
                       entry(-1, lb: 201), entry(0, lb: 203)]
        let lb = WeightFluctuation.compute(
            entries: entries, windowDays: 2, periodDays: 28, unit: .lb, today: today)
        let kg = WeightFluctuation.compute(
            entries: entries, windowDays: 2, periodDays: 28, unit: .kg, today: today)
        XCTAssertEqual(kg.average!, lb.average! / WeightFormatter.kgToLb, accuracy: 0.0001)
    }

    /// Larger windows contain a superset of points, so spread cannot shrink.
    func testWindowSizeMonotonicity() {
        let entries = (0...10).map { entry(-$0, lb: 200 + Double(($0 % 3)) * 1.5) }
        let two = WeightFluctuation.compute(
            entries: entries, windowDays: 2, periodDays: 28, unit: .lb, today: today)
        let four = WeightFluctuation.compute(
            entries: entries, windowDays: 4, periodDays: 28, unit: .lb, today: today)
        XCTAssertGreaterThanOrEqual(four.average!, two.average!)
    }
}
