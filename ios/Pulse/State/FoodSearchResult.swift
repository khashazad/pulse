// Pulse/State/FoodSearchResult.swift
/// A single, source-agnostic food the user can pick from search: a custom food,
/// a remembered USDA food ("my foods"), or a live USDA hit. Carries the
/// `FoodNutrition` needed to scale macros, plus lowercased match terms used for
/// local filtering. `FoodSearchMerge` builds the my-foods set and ranks results.
import Foundation

/// One pickable food in the search list.
struct FoodSearchResult: Identifiable, Equatable {
    /// Where the result came from; drives section + ranking.
    enum Source: Equatable { case myFood, usda }

    let id: String
    let source: Source
    let displayName: String
    let usdaFdcId: Int?
    let usdaDescription: String?
    /// USDA dataset name ("Foundation", "SR Legacy", …); nil for non-USDA rows.
    let usdaDataType: String?
    /// Brand owner for Branded USDA foods; nil otherwise.
    let usdaBrandOwner: String?
    let customFoodId: UUID?
    let nutrition: FoodNutrition
    let matchTerms: [String]

    /// Builds a result from a custom food.
    /// Inputs:
    ///   - food: the user's custom food.
    init(customFood food: CustomFood) {
        self.id = "custom:\(food.id.uuidString)"
        self.source = .myFood
        self.displayName = food.name
        self.usdaFdcId = nil
        self.usdaDescription = nil
        self.usdaDataType = nil
        self.usdaBrandOwner = nil
        self.customFoodId = food.id
        self.nutrition = FoodNutrition(basis: food.basis, servingSize: food.servingSize,
                                       servingSizeUnit: food.servingSizeUnit, caloriesPerBasis: food.calories,
                                       proteinGPerBasis: food.proteinG, carbsGPerBasis: food.carbsG, fatGPerBasis: food.fatG)
        self.matchTerms = [food.name.lowercased()]
    }

    /// Builds a result from a USDA-pointer memory row. Returns nil if the row is
    /// not a fully-populated USDA memory (missing fdc id, basis, or macros).
    /// Inputs:
    ///   - entry: a `food_memory` row.
    init?(memoryUSDA entry: FoodMemoryEntry) {
        guard let fdc = entry.usdaFdcId, let basis = entry.basis,
              let cal = entry.calories, let p = entry.proteinG, let c = entry.carbsG, let f = entry.fatG
        else { return nil }
        self.id = "memory:\(entry.id.uuidString)"
        self.source = .myFood
        self.displayName = entry.name
        self.usdaFdcId = fdc
        self.usdaDescription = entry.usdaDescription
        self.usdaDataType = nil
        self.usdaBrandOwner = nil
        self.customFoodId = nil
        self.nutrition = FoodNutrition(basis: basis, servingSize: entry.servingSize,
                                       servingSizeUnit: entry.servingSizeUnit, caloriesPerBasis: cal,
                                       proteinGPerBasis: p, carbsGPerBasis: c, fatGPerBasis: f)
        self.matchTerms = ([entry.name] + entry.aliases).map { $0.lowercased() }
    }

    /// Builds a result from a live USDA search hit (macros are per-100g).
    /// Inputs:
    ///   - hit: a `GET /usda/search` row.
    init(usda hit: USDAFoodResult) {
        self.id = "usda:\(hit.fdcId)"
        self.source = .usda
        self.displayName = hit.description
        self.usdaFdcId = hit.fdcId
        self.usdaDescription = hit.description
        self.usdaDataType = hit.dataType
        self.usdaBrandOwner = hit.brandOwner
        self.customFoodId = nil
        self.nutrition = FoodNutrition(basis: .per100g, servingSize: hit.servingSize,
                                       servingSizeUnit: hit.servingSizeUnit, caloriesPerBasis: hit.calories,
                                       proteinGPerBasis: hit.proteinG, carbsGPerBasis: hit.carbsG, fatGPerBasis: hit.fatG)
        self.matchTerms = [hit.description.lowercased()]
    }
}

/// Pure helpers to assemble and rank search results client-side.
enum FoodSearchMerge {
    /// Shared name ordering for search rows (locale-aware, case-insensitive).
    /// Used by both query ranking and the browse list so the visible order
    /// doesn't shuffle when the user starts typing.
    /// Inputs:
    ///   - a: the first result.
    ///   - b: the second result.
    /// Outputs: true when `a` orders before `b` by display name.
    static func nameAscending(_ a: FoodSearchResult, _ b: FoodSearchResult) -> Bool {
        a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
    }

    /// Builds the "my foods" set: every custom food, plus USDA-pointer memory
    /// rows. Memory rows that point at a custom food are dropped (the custom
    /// food already represents them).
    /// Inputs:
    ///   - customFoods: the user's custom foods.
    ///   - memory: the user's food-memory rows.
    /// Outputs: deduped my-food results (unranked).
    static func myFoods(customFoods: [CustomFood], memory: [FoodMemoryEntry]) -> [FoodSearchResult] {
        var out = customFoods.map { FoodSearchResult(customFood: $0) }
        out += memory.compactMap { entry in
            entry.customFoodId == nil ? FoodSearchResult(memoryUSDA: entry) : nil
        }
        return out
    }

    /// Filters my-foods by query and appends deduped USDA hits.
    /// Inputs:
    ///   - query: raw search text.
    ///   - myFoods: the pre-built my-foods set.
    ///   - usda: live USDA hits for this query.
    /// Outputs: my-foods first (prefix matches before substring), then USDA hits
    ///   whose fdc id isn't already in my-foods. Empty when the query is blank.
    static func results(query: String, myFoods: [FoodSearchResult], usda: [USDAFoodResult]) -> [FoodSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        let matched = myFoods.filter { r in r.matchTerms.contains { $0.contains(q) } }
        let ranked = matched.sorted { a, b in
            let ap = a.matchTerms.contains { $0.hasPrefix(q) }
            let bp = b.matchTerms.contains { $0.hasPrefix(q) }
            if ap != bp { return ap }
            return nameAscending(a, b)
        }

        let myFdcIds = Set(myFoods.compactMap { $0.usdaFdcId })
        let usdaResults = usda
            .filter { !myFdcIds.contains($0.fdcId) }
            .map { FoodSearchResult(usda: $0) }

        return ranked + usdaResults
    }
}

extension FoodSearchResult {
    /// Synthesizes a pickable result from an existing meal item so its quantity
    /// can be re-entered and rescaled in `QuantityEntryView` without a network
    /// call. Per-basis macros are the item's stored macros divided by its
    /// normalized quantity value; the basis is derived from the stored unit
    /// ("g" → per-100g, "serving" → per-serving, anything else → per-unit).
    /// Returns nil when the item has no positive normalized quantity value
    /// (free-text quantities can't be linearly rescaled).
    /// Inputs:
    ///   - mealItem: the saved item being edited.
    /// Outputs: a pickable result whose `nutrition` reproduces the item's macros
    ///   at its current quantity, or nil when the item has no positive normalized
    ///   quantity value.
    init?(mealItem: MealItem) {
        guard let value = mealItem.normalizedQuantityValue, value > 0 else { return nil }
        let unit = (mealItem.normalizedQuantityUnit ?? "").lowercased()
        let basis: FoodBasis
        let perBasisFactor: Double   // multiply (macro / value) by this to get per-basis
        switch unit {
        case "g", "gram", "grams":
            basis = .per100g
            perBasisFactor = 100
        case "serving", "servings":
            basis = .perServing
            perBasisFactor = 1
        default:
            basis = .perUnit
            perBasisFactor = 1
        }
        let scale = perBasisFactor / value
        self.id = "mealitem:\(mealItem.id.uuidString)"
        self.source = .myFood
        self.displayName = mealItem.displayName
        self.usdaFdcId = mealItem.usdaFdcId
        self.usdaDescription = mealItem.usdaDescription
        self.usdaDataType = nil
        self.usdaBrandOwner = nil
        self.customFoodId = mealItem.customFoodId
        self.nutrition = FoodNutrition(
            basis: basis,
            servingSize: nil,
            servingSizeUnit: nil,
            caloriesPerBasis: Int((Double(mealItem.calories) * scale).rounded()),
            proteinGPerBasis: mealItem.proteinG * scale,
            carbsGPerBasis: mealItem.carbsG * scale,
            fatGPerBasis: mealItem.fatG * scale)
        self.matchTerms = [mealItem.displayName.lowercased()]
    }
}
