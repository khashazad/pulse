import Foundation

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
        case consumedAt = "consumed_at"
        case createdAt = "created_at"
    }
}
