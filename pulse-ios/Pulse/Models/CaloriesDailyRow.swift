/// Wire model for a single (date, calories) point used in calorie history charts.
/// Decodes the server's `log_date` field into a Swift `Date`.
/// Used by analytics/history views that plot daily calorie intake over time.
import Foundation

/// Single day's total calorie intake, keyed by date.
struct CaloriesDailyRow: Codable, Hashable {
    let date: Date
    let calories: Int

    enum CodingKeys: String, CodingKey {
        case date = "log_date"
        case calories
    }
}
