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
        /// Rounds a gram value to one decimal place.
        func tenth(_ v: Double) -> Double { (v * factor * 10).rounded() / 10 }
        return MacroTotals(
            calories: Int((Double(calories) * factor).rounded()),
            proteinG: tenth(proteinG),
            carbsG: tenth(carbsG),
            fatG: tenth(fatG)
        )
    }
}
