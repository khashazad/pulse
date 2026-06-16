// Pulse/Models/Food.swift
/// Codable wire models for the grouped-browse `/foods` endpoints. A `Food` is a
/// thin parent (name + aliases + default portion) owning portion variants; each
/// `FoodPortion` is one `custom_foods` row projected for nesting (its
/// `customFoodId` is what `log_food`/the detail screen act on). snake_case JSON
/// maps to camelCase via explicit CodingKeys. Server-only columns
/// (created_at/updated_at/normalized_name/user_key) are intentionally omitted —
/// the decoder ignores unknown keys.
import Foundation

/// One portion variant nested inside a `Food`.
struct FoodPortion: Codable, Equatable, Hashable, Identifiable {
    let customFoodId: UUID
    let label: String?
    let basis: FoodBasis
    let servingSize: Double?
    let servingSizeUnit: String?
    let calories: Int
    let proteinG: Double
    let carbsG: Double
    let fatG: Double

    /// Satisfies `Identifiable` by aliasing the portion's `customFoodId`.
    /// Outputs: the portion's custom-food UUID.
    var id: UUID { customFoodId }

    enum CodingKeys: String, CodingKey {
        case customFoodId = "custom_food_id"
        case label, basis
        case servingSize = "serving_size"
        case servingSizeUnit = "serving_size_unit"
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
    }
}

/// A grouped food: a parent owning one or more portions.
struct Food: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let notes: String?
    let defaultPortionId: UUID?
    let aliases: [String]
    let portions: [FoodPortion]

    enum CodingKeys: String, CodingKey {
        case id, name, notes, aliases, portions
        case defaultPortionId = "default_portion_id"
    }

    /// The portion to represent the collapsed row — the explicit default when set
    /// and still present, else the first portion (matches the server's fallback).
    /// Outputs: the representative portion, or nil only when `portions` is empty.
    var representativePortion: FoodPortion? {
        if let id = defaultPortionId, let match = portions.first(where: { $0.customFoodId == id }) {
            return match
        }
        return portions.first
    }
}

/// Envelope for `GET /foods`: grouped foods plus ungrouped standalone custom foods.
struct FoodList: Codable, Equatable {
    let foods: [Food]
    let standalones: [CustomFood]
}
