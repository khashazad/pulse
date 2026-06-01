/// Wire models for saved meals (named bundles of food items).
/// Defines the list-row shape (`MealSummary`), list envelope, the full
/// `Meal` record with its `MealItem`s, and a `totals` extension that sums
/// the items' macros. Used by the meals browse, detail, and log flows.
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

    /// Decodes a `MealSummary`, defaulting `aliases` to `[]` when the server omits the field.
    /// - Inputs:
    ///   - decoder: the decoder positioned at a `MealSummary` JSON object.
    /// - Exceptions: rethrows any `DecodingError` from missing required keys or type mismatches.
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

/// Request body for `POST /meals/{id}/log`. `consumedAt` drives backdated
/// logging of a saved meal's items; encode it through `JSONEncoder.pulseDefault()`
/// so it serializes as a naive wall-clock datetime the server can project onto
/// the owning calendar day. Leave `consumedAt` `nil` to log against the server's
/// "now" (the key is then omitted from the request body).
struct LogMealRequest: Encodable, Equatable {
    let consumedAt: Date?

    enum CodingKeys: String, CodingKey {
        case consumedAt = "consumed_at"
    }
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

    /// Decodes a `Meal`, defaulting `aliases` to `[]` when the server omits the field.
    /// - Inputs:
    ///   - decoder: the decoder positioned at a `Meal` JSON object.
    /// - Exceptions: rethrows any `DecodingError` from missing required keys or type mismatches.
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

/// One ingredient row inside a saved `Meal`, with its own macros and source refs.
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

/// Convenience macro aggregation over a meal's items.
extension Meal {
    var totals: MacroTotals {
        let cals = items.reduce(0) { $0 + $1.calories }
        let p = items.reduce(0.0) { $0 + $1.proteinG }
        let c = items.reduce(0.0) { $0 + $1.carbsG }
        let f = items.reduce(0.0) { $0 + $1.fatG }
        return MacroTotals(calories: cals, proteinG: p, carbsG: c, fatG: f)
    }
}
