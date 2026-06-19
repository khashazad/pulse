// Pulse/Models/NewMealItem.swift
/// Client request value for one item in `POST /meals` — mirrors the server's
/// `MealItemCreate` wire shape (snake_case via CodingKeys). `id` is local only
/// (for SwiftUI lists) and is deliberately excluded from the encoded body. Two
/// pure factories build items from a logged `FoodEntry` (1:1) or a Prep
/// `BatchFoodItem` (deriving a human quantity from its typed/weighed amount).
import Foundation

/// One ingredient in a meal being created.
struct NewMealItem: Encodable, Equatable, Identifiable {
    let id: UUID
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

    // `id` is intentionally omitted so it is not encoded into the request body.
    enum CodingKeys: String, CodingKey {
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
    }
}

extension NewMealItem {
    /// Builds a meal item from a logged food entry (fields pass straight
    /// through; the entry already carries a real quantity and macros).
    /// Inputs:
    ///   - entry: the logged `FoodEntry` to convert.
    /// Outputs: an equivalent `NewMealItem`.
    static func from(entry: FoodEntry) -> NewMealItem {
        NewMealItem(
            id: UUID(),
            displayName: entry.displayName,
            quantityText: entry.quantityText,
            normalizedQuantityValue: entry.normalizedQuantityValue,
            normalizedQuantityUnit: entry.normalizedQuantityUnit,
            usdaFdcId: entry.usdaFdcId,
            usdaDescription: entry.usdaDescription,
            customFoodId: entry.customFoodId,
            calories: entry.calories,
            proteinG: entry.proteinG,
            carbsG: entry.carbsG,
            fatG: entry.fatG)
    }

    /// Builds a meal item from a Prep batch item, deriving a human quantity
    /// string and normalized value from its typed/weighed amount. Macros come
    /// from the batch item's already-scaled `macros`.
    /// Inputs:
    ///   - item: the `BatchFoodItem` produced by `QuantityEntryView`.
    ///   - containers: containers available, used to net out the tare for
    ///     weighed quantities.
    /// Outputs: an equivalent `NewMealItem`.
    static func from(batchItem item: BatchFoodItem, containers: [Container]) -> NewMealItem {
        let q = quantity(for: item, containers: containers)
        return NewMealItem(
            id: item.id,
            displayName: item.displayName,
            quantityText: q.text,
            normalizedQuantityValue: q.value,
            normalizedQuantityUnit: q.unit,
            usdaFdcId: item.usdaFdcId,
            usdaDescription: item.usdaDescription,
            customFoodId: item.customFoodId,
            calories: item.macros.calories,
            proteinG: item.macros.proteinG,
            carbsG: item.macros.carbsG,
            fatG: item.macros.fatG)
    }

    /// Derives `(text, value, unit)` for a batch item's quantity.
    /// Inputs:
    ///   - item: the batch item whose quantity is being described.
    ///   - containers: containers, for tare lookup in the weighed case.
    /// Outputs: the human quantity text plus normalized value/unit.
    private static func quantity(
        for item: BatchFoodItem, containers: [Container]
    ) -> (text: String, value: Double?, unit: String?) {
        switch item.quantity {
        case let .typed(value, unit):
            switch unit {
            case .grams:
                return ("\(format(value)) g", value, "g")
            case .servings:
                let word = value == 1 ? "serving" : "servings"
                return ("\(format(value)) \(word)", value, "serving")
            case .units:
                let word = value == 1 ? "unit" : "units"
                return ("\(format(value)) \(word)", value, "unit")
            }
        case let .weighed(grossG):
            let tare = containers.first { $0.id == item.containerId }?.tareWeightG ?? 0
            let net = max(0, grossG - tare)
            return ("\(format(net)) g", net, "g")
        }
    }

    /// Formats a quantity number, dropping a trailing ".0" for whole values.
    /// Inputs:
    ///   - v: the numeric quantity.
    /// Outputs: a compact string (e.g. "2", "1.5").
    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
