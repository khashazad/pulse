/// Inline macro readout shared by the day-entries rows.
/// Renders a colored dot + short macro label + grams, used by `EntryRow` and
/// `MealGroupRow` so both produce identical per-macro chips.
import SwiftUI

/// Inline macro readout: colored dot + short label + grams.
struct MacroLineView: View {
    /// Which macro determines color and short label.
    let macro: Theme.Macro
    /// Grams to display (rounded for output).
    let grams: Double

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(macro.color)
                .frame(width: 5, height: 5)
            Text(macro.short)
                .foregroundStyle(Theme.FG.secondary)
            Text("\(Int(grams.rounded()))g")
                .monospacedDigit()
                .foregroundStyle(Theme.FG.primary)
        }
    }
}
