/// Pure helpers for the weight-backfill flow.
/// Currently computes the date the weight screen's "+" preselects when the
/// user backfills a missed day. No SwiftUI; fully unit-testable.
import Foundation

/// Namespace for weight-backfill date logic.
enum WeightBackfill {
    /// Computes the default date to preselect when backfilling a missed weight:
    /// the most recent **past** day (starting at yesterday) without an entry.
    /// Today is intentionally skipped because it has its own dedicated card.
    ///
    /// - Parameters:
    ///   - entries: The currently loaded weight entries in any order.
    ///   - today: The anchor "today" date; start-of-day is used internally.
    ///     Defaults to `Date()` (the current moment).
    ///   - lowerBound: The earliest selectable day, matching the screen's load
    ///     window floor.
    /// - Returns: The most recent day in the range `yesterday...lowerBound`
    ///   that has no corresponding entry. If every day in that range is already
    ///   logged, returns yesterday. The result is never earlier than
    ///   `lowerBound` and never later than yesterday.
    static func defaultBackfillDate(entries: [WeightEntry],
                                    today: Date = Date(),
                                    lowerBound: Date) -> Date {
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: today)
        let startLower = cal.startOfDay(for: lowerBound)
        // `date(byAdding:)` only returns nil for malformed input, which a
        // start-of-day Date never is. Guard rather than coalesce to `startToday`
        // so the impossible case can never hand back today (which the contract
        // forbids); fall back to the earliest selectable day instead.
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: startToday) else {
            return startLower
        }
        let logged = Set(entries.map { cal.startOfDay(for: $0.date) })

        var day = yesterday
        while day >= startLower {
            if !logged.contains(day) { return day }
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return yesterday
    }
}
