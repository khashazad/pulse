/// A single bar filled with protein/carbs/fat color segments sized by each macro's
/// calorie share (protein at the bottom, fat on top). Shared by the week / month /
/// year intake charts. Falls back to a faint placeholder when there are no macros.
import SwiftUI

/// Vertical macro-composition fill for one bar, driven by `MacroFractions`.
struct StackedMacroBar: View {
    /// Normalized protein/carbs/fat shares (each 0–1), or nil for an unlogged/empty bar.
    let fractions: MacroFractions?

    var body: some View {
        GeometryReader { geo in
            if let f = fractions {
                // Carbs + protein get exact proportional heights; fat (top) absorbs the
                // sub-pixel remainder via maxHeight so the segments always fill the bar
                // with no gap from independent rounding.
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.Macro.fat.color).frame(maxHeight: .infinity)
                    Rectangle().fill(Theme.Macro.carbs.color).frame(height: geo.size.height * f.carbs)
                    Rectangle().fill(Theme.Macro.protein.color).frame(height: geo.size.height * f.protein)
                }
            } else {
                Rectangle().fill(Theme.CTP.surface1.opacity(0.6))
            }
        }
    }
}
