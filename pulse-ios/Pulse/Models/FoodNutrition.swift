// Pulse/Models/FoodNutrition.swift
/// Basis-aware nutrition for a food: per-basis macros plus the rules for
/// scaling them to a chosen quantity and for deciding whether the quantity may
/// be obtained by weighing. Shared by search results and persisted batch items.
import Foundation

/// The unit a food's macros are quoted against.
enum FoodBasis: String, Codable, Equatable {
    case per100g = "per_100g"
    case perServing = "per_serving"
    case perUnit = "per_unit"
}

/// The unit used when a quantity is typed (vs weighed); keyed to the basis.
enum QuantityUnit: String, Codable, Equatable {
    case grams
    case servings
    case units
}

/// Per-basis macros plus scaling/weighing rules for one food.
struct FoodNutrition: Codable, Equatable {
    let basis: FoodBasis
    let servingSize: Double?
    let servingSizeUnit: String?
    let caloriesPerBasis: Int
    let proteinGPerBasis: Double
    let carbsGPerBasis: Double
    let fatGPerBasis: Double

    /// Whether a quantity can be derived by weighing (i.e. from net grams).
    /// True for per_100g; for per_serving only when the serving is in grams;
    /// never for per_unit (a count can't be derived from mass).
    var allowsWeighing: Bool {
        switch basis {
        case .per100g: return true
        case .perServing: return servingSizeUnit?.lowercased() == "g" && (servingSize ?? 0) > 0
        case .perUnit: return false
        }
    }

    /// The unit shown for typed entry for this basis.
    var typeUnit: QuantityUnit {
        switch basis {
        case .per100g: return .grams
        case .perServing: return .servings
        case .perUnit: return .units
        }
    }

    /// Macros for a weighed net-gram amount.
    /// Inputs:
    ///   - netGrams: gross scale reading minus container tare; must be >= 0.
    /// Outputs: scaled `MacroTotals`, or nil when weighing is invalid for this basis.
    func macros(netGrams: Double) -> MacroTotals? {
        guard netGrams >= 0 else { return nil }
        switch basis {
        case .per100g:
            return scaled(by: netGrams / 100.0)
        case .perServing:
            guard allowsWeighing, let size = servingSize, size > 0 else { return nil }
            return scaled(by: netGrams / size)
        case .perUnit:
            return nil
        }
    }

    /// Macros for a typed quantity.
    /// Inputs:
    ///   - value: numeric quantity in `unit`; must be >= 0.
    ///   - unit: the typed unit; must equal `typeUnit` for this basis.
    /// Outputs: scaled `MacroTotals`, or nil when the unit doesn't match the basis.
    func macros(typedValue value: Double, unit: QuantityUnit) -> MacroTotals? {
        guard value >= 0, unit == typeUnit else { return nil }
        switch basis {
        case .per100g: return scaled(by: value / 100.0)
        case .perServing, .perUnit: return scaled(by: value)
        }
    }

    /// Scales the per-basis macros by a multiplier, rounding calories to Int.
    /// Inputs:
    ///   - m: dimensionless multiplier (e.g. grams/100, or a serving count).
    /// Outputs: the scaled `MacroTotals`.
    private func scaled(by m: Double) -> MacroTotals {
        MacroTotals(
            calories: Int((Double(caloriesPerBasis) * m).rounded()),
            proteinG: proteinGPerBasis * m,
            carbsG: carbsGPerBasis * m,
            fatG: fatGPerBasis * m
        )
    }
}
