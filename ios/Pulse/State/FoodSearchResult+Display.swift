// Pulse/State/FoodSearchResult+Display.swift
/// Pure display formatting for food-search rows and the quantity sheet:
/// per-basis macro captions, USDA disambiguation badges, and a human
/// basis-context line. Kept UI-free so it unit-tests without rendering.
import Foundation

extension FoodNutrition {
    /// Formats a serving-size double without a trailing ".0" (1.0 → "1", 0.5 → "0.5").
    /// Inputs:
    ///   - value: the numeric serving size.
    /// Outputs: a compact decimal string.
    static func compactNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// One-line human description of this food's basis for the quantity sheet,
    /// e.g. "1 serving = 250 g" or "Macros are per 100 g".
    /// Outputs: the basis-context string (never nil; missing serving size is stated).
    var basisContextLine: String {
        switch basis {
        case .per100g:
            return "Macros are per 100 g"
        case .perServing:
            if let size = servingSize, let unit = servingSizeUnit {
                return "1 serving = \(Self.compactNumber(size)) \(unit)"
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
        let macros = "\(n.caloriesPerBasis) kcal"
            + " · P \(Int(n.proteinGPerBasis.rounded()))"
            + " · C \(Int(n.carbsGPerBasis.rounded()))"
            + " · F \(Int(n.fatGPerBasis.rounded()))"
        return "\(macros) / \(basisSuffix)"
    }

    /// The basis suffix for `caption`: "100g", "serving (250 g)",
    /// "serving — size not set", or "unit".
    /// Outputs: the suffix string.
    private var basisSuffix: String {
        switch nutrition.basis {
        case .per100g:
            return "100g"
        case .perServing:
            if let size = nutrition.servingSize, let unit = nutrition.servingSizeUnit {
                return "serving (\(FoodNutrition.compactNumber(size)) \(unit))"
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
