/// Macro-composition helpers: express a day's (or a span's) protein/carbs/fat as
/// shares of its macro-derived calories, for the Month view's stacked-segment bars.
/// Uses Atwater factors (protein 4, carbs 4, fat 9 kcal/g) to weight each macro by
/// the energy it contributes rather than by raw grams.
import Foundation

/// Whole-number protein/carbs/fat percentages of a span's macro calories.
/// The three values are normalized to sum to exactly 100 (fat absorbs rounding).
struct MacroSplit: Equatable {
    let proteinPct: Int
    let carbsPct: Int
    let fatPct: Int
}

/// Calories contributed by each macro using Atwater factors.
/// Inputs:
///   - proteinG: protein grams.
///   - carbsG: carbohydrate grams.
///   - fatG: fat grams.
/// Outputs: per-macro calorie tuple (protein, carbs, fat).
private func macroCalories(proteinG: Double, carbsG: Double, fatG: Double) -> (protein: Double, carbs: Double, fat: Double) {
    (proteinG * 4, carbsG * 4, fatG * 9)
}

/// Normalized 0–1 fractions of macro calories, used for segment heights.
/// Inputs:
///   - proteinG: protein grams.
///   - carbsG: carbohydrate grams.
///   - fatG: fat grams.
/// Outputs: per-macro fraction tuple summing to 1, or nil when there are no macro calories.
func macroFractions(proteinG: Double, carbsG: Double, fatG: Double) -> (protein: Double, carbs: Double, fat: Double)? {
    let cals = macroCalories(proteinG: proteinG, carbsG: carbsG, fatG: fatG)
    let total = cals.protein + cals.carbs + cals.fat
    guard total > 0 else { return nil }
    return (cals.protein / total, cals.carbs / total, cals.fat / total)
}

/// Whole-number macro percentages, or nil when there are no macro calories to split.
/// Inputs:
///   - proteinG: protein grams.
///   - carbsG: carbohydrate grams.
///   - fatG: fat grams.
/// Outputs: a `MacroSplit` summing to 100, or nil for an empty span.
func macroSplit(proteinG: Double, carbsG: Double, fatG: Double) -> MacroSplit? {
    guard let f = macroFractions(proteinG: proteinG, carbsG: carbsG, fatG: fatG) else { return nil }
    var p = Int((f.protein * 100).rounded())
    var c = Int((f.carbs * 100).rounded())
    var fat = Int((f.fat * 100).rounded())
    // Push the ±1 rounding drift onto the largest share so the three percentages
    // always sum to exactly 100 and none can go negative (the largest is ≥ 33%).
    let drift = 100 - (p + c + fat)
    if f.protein >= f.carbs, f.protein >= f.fat {
        p += drift
    } else if f.carbs >= f.fat {
        c += drift
    } else {
        fat += drift
    }
    return MacroSplit(proteinPct: p, carbsPct: c, fatPct: fat)
}

extension DailyLog {
    /// This day's macro composition as normalized segment fractions (protein, carbs, fat).
    /// Outputs: fractions summing to 1, or nil when the day has no macros.
    var macroFractions: (protein: Double, carbs: Double, fat: Double)? {
        Pulse.macroFractions(proteinG: totalProteinG, carbsG: totalCarbsG, fatG: totalFatG)
    }

    /// This day's macro composition as whole-number percentages.
    /// Outputs: a `MacroSplit` summing to 100, or nil when the day has no macros.
    var macroSplit: MacroSplit? {
        Pulse.macroSplit(proteinG: totalProteinG, carbsG: totalCarbsG, fatG: totalFatG)
    }
}

extension Array where Element == DailyLog {
    /// Aggregate macro split across the collection's logged days (sums grams over days
    /// with entries — matching the `avg*` helpers — then splits).
    /// Outputs: a `MacroSplit` summing to 100, or nil when the span has no macros.
    var macroSplit: MacroSplit? {
        let logged = filter { $0.entryCount > 0 }
        let p = logged.map(\.totalProteinG).reduce(0, +)
        let c = logged.map(\.totalCarbsG).reduce(0, +)
        let f = logged.map(\.totalFatG).reduce(0, +)
        return Pulse.macroSplit(proteinG: p, carbsG: c, fatG: f)
    }
}
