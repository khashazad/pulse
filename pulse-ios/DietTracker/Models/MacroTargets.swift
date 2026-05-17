/// Wire model for the user's daily macro targets plus optional target weight.
/// Used by the targets-editing UI and by `DailySummary` to compute remaining macros.
import Foundation

/// User's daily calorie/macro targets and optional goal weight.
struct MacroTargets: Codable, Equatable {
    let calories: Int
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let targetWeightLb: Double?

    enum CodingKeys: String, CodingKey {
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case targetWeightLb = "target_weight_lb"
    }
}
