// Pulse/Models/BatchFoodItem.swift
/// One food in the in-app meal-prep batch: which food, how much, where it was
/// weighed/portioned, and the macros computed at the time it was added. Codable
/// so the whole batch round-trips through `PrepStatePersistence`.
import Foundation

/// How an item's quantity was provided.
enum BatchQuantity: Codable, Equatable {
    /// Weighed: the raw scale reading; net grams = gross − container tare.
    case weighed(grossG: Double)
    /// Typed: a numeric value in `unit` (grams/servings/units per the food's basis).
    case typed(value: Double, unit: QuantityUnit)
}

/// A food added to the batch, with its computed macros frozen in.
struct BatchFoodItem: Identifiable, Codable, Equatable {
    let id: UUID
    let displayName: String
    let usdaFdcId: Int?
    let usdaDescription: String?
    let customFoodId: UUID?
    let nutrition: FoodNutrition
    let quantity: BatchQuantity
    /// Weigh container (tare source) or, in typed mode, an optional label of
    /// which container the food went into.
    let containerId: UUID?
    /// Macros computed when the item was added (already scaled by quantity).
    let macros: MacroTotals

    /// Whether the item carries a loggable food source. Single source of truth
    /// for the apply-to-days gate (`PrepView.canApply`) and the payload builder's
    /// skip rule (`ApplyBatchModel.buildEntries`): the server's entry validator
    /// requires exactly one of USDA / custom-food per entry.
    /// Outputs: true when the item has a USDA or custom-food reference.
    var hasSource: Bool { usdaFdcId != nil || customFoodId != nil }
}
