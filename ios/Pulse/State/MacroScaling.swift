import Foundation

/// Non-wire scaling helper for `MacroTotals`. Lives in State/ (not Models/)
/// because Models/ holds wire DTOs only; this is pure client math shared by the
/// Prep per-portion preview and the apply-to-days payload builder.
extension MacroTotals {
    /// Scales this total to `count` portions out of `portions`, i.e. multiplies
    /// by `count / portions`. Calories round to the nearest Int; gram macros
    /// round to 0.1 g. Degenerate inputs are clamped: `portions` below 1 acts
    /// as 1, negative `count` as 0.
    /// Inputs:
    ///   - count: how many portions to take (≥ 0 after clamping).
    ///   - portions: how many portions the whole divides into (≥ 1 after clamping).
    /// Outputs: a new `MacroTotals` scaled by `count / portions`.
    func scaled(count: Int, portions: Int) -> MacroTotals {
        let factor = Double(max(0, count)) / Double(max(1, portions))
        /// Rounds a gram value to one decimal place after scaling by the
        /// pre-computed `factor`.
        /// Inputs:
        ///   - v: the raw gram value to scale and round.
        /// Outputs: `v * factor`, rounded to the nearest 0.1 g.
        func tenth(_ v: Double) -> Double { (v * factor * 10).rounded() / 10 }
        return MacroTotals(
            calories: Int((Double(calories) * factor).rounded()),
            proteinG: tenth(proteinG),
            carbsG: tenth(carbsG),
            fatG: tenth(fatG)
        )
    }

    /// Formats the totals as a compact single line, e.g. "260 kcal · P 5 · C 56 · F 1".
    /// Outputs: a human-readable macro summary string.
    var compactLine: String {
        "\(calories) kcal · P \(Int(proteinG)) · C \(Int(carbsG)) · F \(Int(fatG))"
    }

    /// The additive identity, used as the seed when summing totals.
    static let zero = MacroTotals(calories: 0, proteinG: 0, carbsG: 0, fatG: 0)

    /// Adds two totals field-wise. Single source of truth for macro summation,
    /// shared by `BatchCompositionModel.total` and `ApplyBatchModel`.
    /// Inputs:
    ///   - lhs: the first total.
    ///   - rhs: the second total.
    /// Outputs: a new `MacroTotals` with each field summed.
    static func + (lhs: MacroTotals, rhs: MacroTotals) -> MacroTotals {
        MacroTotals(
            calories: lhs.calories + rhs.calories,
            proteinG: lhs.proteinG + rhs.proteinG,
            carbsG: lhs.carbsG + rhs.carbsG,
            fatG: lhs.fatG + rhs.fatG
        )
    }
}
