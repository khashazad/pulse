// Pulse/State/FoodSearchResult+Display.swift
/// Pure display formatting for food-search rows and the quantity sheet:
/// per-basis macro captions, USDA disambiguation badges, and a human
/// basis-context line. Kept UI-free so it unit-tests without rendering.
import Foundation

extension FoodNutrition {
    /// Human serving-size descriptor, e.g. "250 g" or "1 scoop".
    /// Outputs: the formatted size + unit, or nil when either is unrecorded.
    var servingDescriptor: String? {
        guard let size = servingSize, let unit = servingSizeUnit else { return nil }
        return "\(NumericInput.formatBare(size)) \(unit)"
    }

    /// One-line human description of this food's basis for the quantity sheet,
    /// e.g. "1 serving = 250 g" or "Macros are per 100 g".
    /// Outputs: the basis-context string (never nil; missing serving size is stated).
    var basisContextLine: String {
        switch basis {
        case .per100g:
            return "Macros are per 100 g"
        case .perServing:
            if let descriptor = servingDescriptor {
                return "1 serving = \(descriptor)"
            }
            return "1 serving — size not set"
        case .perUnit:
            return "Macros are per unit"
        }
    }
}

extension FoodSearchResult {
    /// Caption line under the food name: per-basis macros plus a basis suffix,
    /// e.g. "130 kcal · P 25 · C 3 · F 2 / serving (1 scoop)".
    /// Outputs: the formatted caption string.
    var caption: String {
        let n = nutrition
        let perBasis = MacroTotals(
            calories: n.caloriesPerBasis,
            proteinG: n.proteinGPerBasis,
            carbsG: n.carbsGPerBasis,
            fatG: n.fatGPerBasis
        )
        return "\(perBasis.compactLine) / \(basisSuffix)"
    }

    /// The basis suffix for `caption`: "100g", "serving (250 g)",
    /// "serving — size not set", or "unit".
    /// Outputs: the suffix string.
    private var basisSuffix: String {
        switch nutrition.basis {
        case .per100g:
            return "100g"
        case .perServing:
            if let descriptor = nutrition.servingDescriptor {
                return "serving (\(descriptor))"
            }
            return "serving — size not set"
        case .perUnit:
            return "unit"
        }
    }

    /// Small disambiguation badge for USDA rows: the brand owner for Branded
    /// foods, else a short dataset label. Nil for my-foods rows or when the
    /// server didn't send a data type.
    /// Outputs: the badge text, or nil when no badge should render.
    var badge: String? {
        guard source == .usda else { return nil }
        if let brand = usdaBrandOwner, !brand.isEmpty { return brand }
        switch usdaDataType {
        case "Survey (FNDDS)": return "Survey"
        case .some(let other): return other
        case nil: return nil
        }
    }
}
