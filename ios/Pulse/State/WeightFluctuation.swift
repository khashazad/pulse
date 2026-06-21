/// WeightFluctuation: pure functions deriving short-term weight variability.
/// For each rolling N-day window over a lookback period, fluctuation is the
/// max-minus-min spread of weigh-ins inside it (in display units); the headline
/// is the average of all valid windows and `series` drives a sparkline.
/// Role: shared math for FluctuationCard; no I/O, fully testable.
import Foundation

/// Namespace for pure weight-fluctuation analytics.
enum WeightFluctuation {

    /// Minimum number of valid windows required before a headline is shown.
    static let minValidWindows = 3

    /// One rolling window's fluctuation value, plotted at the window end-date.
    struct Point: Hashable, Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    /// Output bundle: headline average, observed range, sample count, and the
    /// per-window series for the sparkline.
    struct Result: Hashable {
        let average: Double?
        let min: Double?
        let max: Double?
        let sampleCount: Int
        let series: [Point]
    }

    /// Computes average within-window spread over a rolling lookback period.
    /// Inputs:
    ///   - entries: weight entries (any order); only those within the period count.
    ///   - windowDays: window length in calendar days (e.g. 2, 3, 4).
    ///   - periodDays: lookback length in calendar days (e.g. 28, 90, 365).
    ///   - unit: display unit; each weight is converted before max-min.
    ///   - today: anchor date for the trailing period (defaults to now).
    /// Outputs: a `Result`; `average`/`min`/`max` are nil when no window is valid.
    static func compute(
        entries: [WeightEntry],
        windowDays: Int,
        periodDays: Int,
        unit: WeightUnit,
        today: Date = .now
    ) -> Result {
        let cal = Calendar(identifier: .gregorian)
        let endDay = cal.startOfDay(for: today)
        guard windowDays >= 1, periodDays >= 1 else {
            return Result(average: nil, min: nil, max: nil, sampleCount: 0, series: [])
        }

        // Index display-unit weights by start-of-day for O(1) per-day lookup.
        var byDay: [Date: Double] = [:]
        for e in entries {
            byDay[cal.startOfDay(for: e.date)] = WeightFormatter.fromLb(e.weightLb, to: unit)
        }

        var values: [Point] = []
        for offset in 0..<periodDays {
            guard let windowEnd = cal.date(byAdding: .day, value: -offset, to: endDay) else { continue }
            var inWindow: [Double] = []
            for back in 0..<windowDays {
                guard let day = cal.date(byAdding: .day, value: -back, to: windowEnd) else { continue }
                if let w = byDay[day] { inWindow.append(w) }
            }
            guard inWindow.count >= 2, let lo = inWindow.min(), let hi = inWindow.max() else { continue }
            values.append(Point(date: windowEnd, value: hi - lo))
        }

        guard !values.isEmpty else {
            return Result(average: nil, min: nil, max: nil, sampleCount: 0, series: [])
        }
        let series = values.sorted { $0.date < $1.date }
        let vals = series.map(\.value)
        let avg = vals.reduce(0, +) / Double(vals.count)
        return Result(average: avg, min: vals.min(), max: vals.max(),
                      sampleCount: series.count, series: series)
    }
}
