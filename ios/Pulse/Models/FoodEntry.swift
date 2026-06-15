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
    /// Whether this entry counts toward day/period totals. Future prep portions
    /// applied from the Prep tab arrive `false` (pending) and flip to `true`
    /// once the user confirms them. Defaults to `true` so any payload predating
    /// the field still reads as a normal, counted entry.
    let isConfirmed: Bool

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
        case isConfirmed = "confirmed"
    }

    /// Memberwise initializer used by tests and previews. `isConfirmed` defaults
    /// to `true` so existing call sites that predate the pending concept keep
    /// building confirmed entries unchanged.
    /// - Parameters mirror the stored properties one-to-one.
    /// - Returns: A `FoodEntry` with the given fields.
    init(
        id: UUID,
        dailyLogId: UUID,
        userKey: String,
        entryGroupId: UUID,
        displayName: String,
        quantityText: String,
        normalizedQuantityValue: Double?,
        normalizedQuantityUnit: String?,
        usdaFdcId: Int?,
        usdaDescription: String?,
        customFoodId: UUID?,
        calories: Int,
        proteinG: Double,
        carbsG: Double,
        fatG: Double,
        mealId: UUID?,
        mealName: String?,
        consumedAt: Date,
        createdAt: Date,
        isConfirmed: Bool = true
    ) {
        self.id = id
        self.dailyLogId = dailyLogId
        self.userKey = userKey
        self.entryGroupId = entryGroupId
        self.displayName = displayName
        self.quantityText = quantityText
        self.normalizedQuantityValue = normalizedQuantityValue
        self.normalizedQuantityUnit = normalizedQuantityUnit
        self.usdaFdcId = usdaFdcId
        self.usdaDescription = usdaDescription
        self.customFoodId = customFoodId
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.mealId = mealId
        self.mealName = mealName
        self.consumedAt = consumedAt
        self.createdAt = createdAt
        self.isConfirmed = isConfirmed
    }

    /// Decodes a `FoodEntry`, tolerating a missing `confirmed` key by defaulting
    /// it to `true` (a normal, counted entry).
    /// - Parameter decoder: The decoder supplying the keyed container.
    /// - Returns: The decoded `FoodEntry`.
    /// - Throws: `DecodingError` when a required field is missing or mistyped.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        dailyLogId = try container.decode(UUID.self, forKey: .dailyLogId)
        userKey = try container.decode(String.self, forKey: .userKey)
        entryGroupId = try container.decode(UUID.self, forKey: .entryGroupId)
        displayName = try container.decode(String.self, forKey: .displayName)
        quantityText = try container.decode(String.self, forKey: .quantityText)
        normalizedQuantityValue = try container.decodeIfPresent(
            Double.self, forKey: .normalizedQuantityValue)
        normalizedQuantityUnit = try container.decodeIfPresent(
            String.self, forKey: .normalizedQuantityUnit)
        usdaFdcId = try container.decodeIfPresent(Int.self, forKey: .usdaFdcId)
        usdaDescription = try container.decodeIfPresent(String.self, forKey: .usdaDescription)
        customFoodId = try container.decodeIfPresent(UUID.self, forKey: .customFoodId)
        calories = try container.decode(Int.self, forKey: .calories)
        proteinG = try container.decode(Double.self, forKey: .proteinG)
        carbsG = try container.decode(Double.self, forKey: .carbsG)
        fatG = try container.decode(Double.self, forKey: .fatG)
        mealId = try container.decodeIfPresent(UUID.self, forKey: .mealId)
        mealName = try container.decodeIfPresent(String.self, forKey: .mealName)
        consumedAt = try container.decode(Date.self, forKey: .consumedAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isConfirmed = try container.decodeIfPresent(Bool.self, forKey: .isConfirmed) ?? true
    }
}
