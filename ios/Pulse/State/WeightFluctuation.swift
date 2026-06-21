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

    /// Output bundle: headline average, sample count, and the per-window series
    /// for the sparkline. The observed range (`min`/`max`) is derived from
    /// `series` rather than stored, so it can never drift out of sync.
    struct Result: Hashable {
        let average: Double?
        let sampleCount: Int
        let series: [Point]

        /// Smallest window fluctuation in `series`, or nil when empty.
        var min: Double? { series.map(\.value).min() }
        /// Largest window fluctuation in `series`, or nil when empty.
        var max: Double? { series.map(\.value).max() }

        /// The no-valid-windows result.
        static let empty = Result(average: nil, sampleCount: 0, series: [])
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
        guard windowDays >= 1, periodDays >= 1 else { return .empty }

        // Index display-unit weights by start-of-day for O(1) per-day lookup.
        var byDay: [Date: Double] = [:]
        for e in entries {
            byDay[cal.startOfDay(for: e.date)] = WeightFormatter.fromLb(e.weightLb, to: unit)
        }

        // Precompute the descending (newest-first) day sequence once, rather
        // than calling Calendar date math inside the window loop. The oldest
        // window end still looks back windowDays-1 days, so the sequence runs
        // periodDays + windowDays - 1 long to cover that overhang.
        var days: [Date] = []
        days.reserveCapacity(periodDays + windowDays - 1)
        var day = endDay
        for _ in 0..<(periodDays + windowDays - 1) {
            days.append(day)
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }

        // Each window ends at days[i] and spans the next windowDays-1 older days.
        var values: [Point] = []
        for i in 0..<Swift.min(periodDays, days.count) {
            var inWindow: [Double] = []
            for j in i..<Swift.min(i + windowDays, days.count) {
                if let w = byDay[days[j]] { inWindow.append(w) }
            }
            guard inWindow.count >= 2, let lo = inWindow.min(), let hi = inWindow.max() else { continue }
            values.append(Point(date: days[i], value: hi - lo))
        }

        guard !values.isEmpty else { return .empty }
        // `values` is built newest-first; reverse for an ascending-by-date series.
        let series = Array(values.reversed())
        let avg = series.map(\.value).reduce(0, +) / Double(series.count)
        return Result(average: avg, sampleCount: series.count, series: series)
    }
}
