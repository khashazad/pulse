/// Wire model for a single (date, calories) point used in calorie history charts.
/// Decodes the server's `log_date` field into a Swift `Date`.
/// Used by analytics/history views that plot daily calorie intake over time.
import Foundation

/// Single day's total calorie intake, keyed by date.
struct CaloriesDailyRow: Codable, Hashable {
    let date: Date
    let calories: Int
    /// User flagged this day "ignore from stats" — dimmed and skipped in trends.
    let excluded: Bool

    enum CodingKeys: String, CodingKey {
        case date = "log_date"
        case calories
        case excluded
    }

    /// Memberwise-style init retained for previews/tests constructing rows directly.
    init(date: Date, calories: Int, excluded: Bool = false) {
        self.date = date
        self.calories = calories
        self.excluded = excluded
    }

    /// Decodes a row, defaulting `excluded` to `false` when the key is absent so
    /// older cached payloads (pre-exclusion field) still decode.
    /// Inputs:
    ///   - decoder: the decoder holding the keyed container.
    /// Exceptions: rethrows any decoding error for the required fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        calories = try c.decode(Int.self, forKey: .calories)
        excluded = try c.decodeIfPresent(Bool.self, forKey: .excluded) ?? false
    }
}
