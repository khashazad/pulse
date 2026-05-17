/// Wire models for aggregated daily macro totals.
/// `DailyLog` is one day's roll-up of calories/macros/entry count; `LogsList`
/// is the multi-day envelope returned by the logs endpoint.
/// Consumed by history and trend views.
import Foundation

/// One day's aggregate calorie/macro totals, identified by its date.
struct DailyLog: Codable, Identifiable, Equatable {
    var id: Date { date }
    let date: Date              // YYYY-MM-DD
    let totalCalories: Int
    let totalProteinG: Double
    let totalCarbsG: Double
    let totalFatG: Double
    let entryCount: Int

    enum CodingKeys: String, CodingKey {
        case date
        case totalCalories = "total_calories"
        case totalProteinG = "total_protein_g"
        case totalCarbsG = "total_carbs_g"
        case totalFatG = "total_fat_g"
        case entryCount = "entry_count"
    }
}

/// Envelope for endpoints returning multiple `DailyLog` rows.
struct LogsList: Codable, Equatable {
    let logs: [DailyLog]
}
