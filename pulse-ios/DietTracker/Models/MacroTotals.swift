/// Wire model for an aggregated macro tuple (calories + protein/carbs/fat).
/// Reused by `DailySummary` for consumed/remaining slots and by `Meal.totals`.
import Foundation

/// Aggregate calorie and macro totals with no date or target context.
struct MacroTotals: Codable, Equatable {
    let calories: Int
    let proteinG: Double
    let carbsG: Double
    let fatG: Double

    enum CodingKeys: String, CodingKey {
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
    }
}
