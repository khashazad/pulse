import Foundation

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

struct LogsList: Codable, Equatable {
    let logs: [DailyLog]
}
