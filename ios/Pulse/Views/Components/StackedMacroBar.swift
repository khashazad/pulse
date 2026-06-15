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

/// Tap-selection treatment shared by the intake bar charts (`DailyKcalBars`,
/// `WeeklyMacroBars`): a hairline focus border and mauve glow when `emphasized`,
/// dimmed when another bar in the row is selected. Centralizing it keeps the
/// selection look in sync across charts.
struct BarEmphasis: ViewModifier {
    /// Whether this bar is the focused one (selected, or the default highlight).
    let emphasized: Bool
    /// Whether another bar is selected, dimming this one.
    let dimmed: Bool

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.barRadius, style: .continuous)
                    .strokeBorder(Theme.FG.primary.opacity(emphasized ? 0.8 : 0), lineWidth: 1.5)
            )
            .opacity(dimmed ? 0.45 : 1)
            .shadow(color: emphasized ? Theme.CTP.mauve.opacity(0.45) : .clear, radius: 6)
    }
}

extension View {
    /// Applies the shared `BarEmphasis` selection treatment.
    /// Inputs:
    ///   - emphasized: whether this bar is focused (selected or default highlight).
    ///   - dimmed: whether another bar is selected, dimming this one.
    /// Outputs: the receiver with the selection border, dim, and glow applied.
    func barEmphasis(emphasized: Bool, dimmed: Bool) -> some View {
        modifier(BarEmphasis(emphasized: emphasized, dimmed: dimmed))
    }
}
