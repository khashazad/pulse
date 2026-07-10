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
    /// User flagged this day "ignore from stats" — averages/trends skip it.
    let excluded: Bool

    enum CodingKeys: String, CodingKey {
        case date
        case totalCalories = "total_calories"
        case totalProteinG = "total_protein_g"
        case totalCarbsG = "total_carbs_g"
        case totalFatG = "total_fat_g"
        case entryCount = "entry_count"
        case excluded
    }

    /// Memberwise-style init retained so call sites (previews, tests, placeholder
    /// day construction) keep building `DailyLog`s directly.
    init(
        date: Date, totalCalories: Int, totalProteinG: Double, totalCarbsG: Double,
        totalFatG: Double, entryCount: Int, excluded: Bool = false
    ) {
        self.date = date
        self.totalCalories = totalCalories
        self.totalProteinG = totalProteinG
        self.totalCarbsG = totalCarbsG
        self.totalFatG = totalFatG
        self.entryCount = entryCount
        self.excluded = excluded
    }

    /// Decodes a `DailyLog`, defaulting `excluded` to `false` when the key is
    /// absent so older cached payloads (pre-exclusion field) still decode.
    /// Inputs:
    ///   - decoder: the decoder holding the keyed container.
    /// Exceptions: rethrows any decoding error for the required fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        totalCalories = try c.decode(Int.self, forKey: .totalCalories)
        totalProteinG = try c.decode(Double.self, forKey: .totalProteinG)
        totalCarbsG = try c.decode(Double.self, forKey: .totalCarbsG)
        totalFatG = try c.decode(Double.self, forKey: .totalFatG)
        entryCount = try c.decode(Int.self, forKey: .entryCount)
        excluded = try c.decodeIfPresent(Bool.self, forKey: .excluded) ?? false
    }
}

/// Envelope for endpoints returning multiple `DailyLog` rows.
struct LogsList: Codable, Equatable {
    let logs: [DailyLog]
}
