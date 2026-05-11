import Foundation

/// Row shape returned by `GET /meals` — includes per-meal aggregate totals.
struct MealSummary: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let normalizedName: String
    let notes: String?
    let aliases: [String]
    let itemCount: Int
    let totalCalories: Int
    let totalProteinG: Double
    let totalCarbsG: Double
    let totalFatG: Double

    enum CodingKeys: String, CodingKey {
        case id, name, notes, aliases
        case normalizedName = "normalized_name"
        case itemCount = "item_count"
        case totalCalories = "total_calories"
        case totalProteinG = "total_protein_g"
        case totalCarbsG = "total_carbs_g"
        case totalFatG = "total_fat_g"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        normalizedName = try c.decode(String.self, forKey: .normalizedName)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        itemCount = try c.decode(Int.self, forKey: .itemCount)
        totalCalories = try c.decode(Int.self, forKey: .totalCalories)
        totalProteinG = try c.decode(Double.self, forKey: .totalProteinG)
        totalCarbsG = try c.decode(Double.self, forKey: .totalCarbsG)
        totalFatG = try c.decode(Double.self, forKey: .totalFatG)
    }

    var totals: MacroTotals {
        MacroTotals(
            calories: totalCalories,
            proteinG: totalProteinG,
            carbsG: totalCarbsG,
            fatG: totalFatG
        )
    }
}

/// `GET /meals` envelope.
struct MealsListResponse: Codable {
    let meals: [MealSummary]
}

/// Full meal returned by `GET /meals/{id}`, including all items.
struct Meal: Codable, Identifiable, Hashable {
    let id: UUID
    let userKey: String
    let name: String
    let normalizedName: String
    let notes: String?
    let aliases: [String]
    let createdAt: Date
    let updatedAt: Date
    let items: [MealItem]

    enum CodingKeys: String, CodingKey {
        case id, name, notes, items, aliases
        case userKey = "user_key"
        case normalizedName = "normalized_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        userKey = try c.decode(String.self, forKey: .userKey)
        name = try c.decode(String.self, forKey: .name)
        normalizedName = try c.decode(String.self, forKey: .normalizedName)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        items = try c.decode([MealItem].self, forKey: .items)
    }
}

struct MealItem: Codable, Identifiable, Hashable {
    let id: UUID
    let mealId: UUID
    let position: Int
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
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, position, calories
        case mealId = "meal_id"
        case displayName = "display_name"
        case quantityText = "quantity_text"
        case normalizedQuantityValue = "normalized_quantity_value"
        case normalizedQuantityUnit = "normalized_quantity_unit"
        case usdaFdcId = "usda_fdc_id"
        case usdaDescription = "usda_description"
        case customFoodId = "custom_food_id"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case createdAt = "created_at"
    }
}

extension Meal {
    var totals: MacroTotals {
        let cals = items.reduce(0) { $0 + $1.calories }
        let p = items.reduce(0.0) { $0 + $1.proteinG }
        let c = items.reduce(0.0) { $0 + $1.carbsG }
        let f = items.reduce(0.0) { $0 + $1.fatG }
        return MacroTotals(calories: cals, proteinG: p, carbsG: c, fatG: f)
    }
}
