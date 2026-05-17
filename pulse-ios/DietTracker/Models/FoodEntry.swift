/// Wire model for a single logged food entry (one row in the day's food list).
/// Captures the display name, quantity, normalized USDA/custom-food refs, computed
/// macros, optional meal grouping, and audit timestamps.
/// Used throughout the logging, editing, and history flows.
import Foundation

/// A single logged food item with its macros, source refs, and timestamps.
struct FoodEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let dailyLogId: UUID
    let userKey: String
    let entryGroupId: UUID
    let displayName: String
    let quantityText: String
    let normalizedQuantityValue: Double?
    let normalizedQuantityUnit: String?
    let usdaFdcId: Int?
    let usdaDescription: String?
    let customFoodId: UUID?
    let calories: Int
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let mealId: UUID?
    let mealName: String?
    let consumedAt: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case dailyLogId = "daily_log_id"
        case userKey = "user_key"
        case entryGroupId = "entry_group_id"
        case displayName = "display_name"
        case quantityText = "quantity_text"
        case normalizedQuantityValue = "normalized_quantity_value"
        case normalizedQuantityUnit = "normalized_quantity_unit"
        case usdaFdcId = "usda_fdc_id"
        case usdaDescription = "usda_description"
        case customFoodId = "custom_food_id"
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case mealId = "meal_id"
        case mealName = "meal_name"
        case consumedAt = "consumed_at"
        case createdAt = "created_at"
    }
}
