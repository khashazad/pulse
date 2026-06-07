// Pulse/Models/FoodSearchDTOs.swift
/// Codable wire models for the food-search endpoints the iOS client reads:
/// `GET /usda/search`, `GET /custom-foods`, and `GET /food-memory`. snake_case
/// JSON maps to camelCase via explicit CodingKeys; macros are at each row's basis.
import Foundation

/// One normalized USDA search hit. Macros are per-100g.
struct USDAFoodResult: Codable, Equatable {
    let fdcId: Int
    let description: String
    let calories: Int
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let servingSize: Double?
    let servingSizeUnit: String?
    /// USDA dataset ("Foundation", "SR Legacy", "Branded", "Survey (FNDDS)");
    /// nil from older servers that don't send it.
    let dataType: String?
    /// Brand owner for Branded foods; nil otherwise / from older servers.
    let brandOwner: String?

    enum CodingKeys: String, CodingKey {
        case fdcId = "fdc_id"
        case description
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case servingSize = "serving_size"
        case servingSizeUnit = "serving_size_unit"
        case dataType = "data_type"
        case brandOwner = "brand_owner"
    }
}

/// Envelope for `GET /usda/search`.
struct USDASearchResponse: Codable, Equatable {
    let results: [USDAFoodResult]
}

/// A user-defined custom food. Macros are quoted at `basis`.
struct CustomFood: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let basis: FoodBasis
    let servingSize: Double?
    let servingSizeUnit: String?
    let calories: Int
    let proteinG: Double
    let carbsG: Double
    let fatG: Double

    enum CodingKeys: String, CodingKey {
        case id, name, basis
        case servingSize = "serving_size"
        case servingSizeUnit = "serving_size_unit"
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
    }
}

/// Envelope for `GET /custom-foods`.
struct CustomFoodList: Codable, Equatable {
    let customFoods: [CustomFood]

    enum CodingKeys: String, CodingKey {
        case customFoods = "custom_foods"
    }
}

/// A remembered food. Points at a USDA food (macros populated) or a custom
/// food (macros/basis null — resolved from the linked custom food).
struct FoodMemoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let usdaFdcId: Int?
    let usdaDescription: String?
    let customFoodId: UUID?
    let basis: FoodBasis?
    let servingSize: Double?
    let servingSizeUnit: String?
    let calories: Int?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let aliases: [String]

    enum CodingKeys: String, CodingKey {
        case id, name
        case usdaFdcId = "usda_fdc_id"
        case usdaDescription = "usda_description"
        case customFoodId = "custom_food_id"
        case basis
        case servingSize = "serving_size"
        case servingSizeUnit = "serving_size_unit"
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case aliases
    }
}

/// Envelope for `GET /food-memory`.
struct FoodMemoryList: Codable, Equatable {
    let entries: [FoodMemoryEntry]
}
