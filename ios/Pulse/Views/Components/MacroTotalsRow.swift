/// Row of three macro chips (P/C/F) shown under the kcal ring or meal hero card.
/// Each chip shows current grams, optional target, and a thin progress capsule.
import SwiftUI

/// Horizontal row of protein/carbs/fat chips with optional per-macro targets.
struct MacroTotalsRow: View {
    let totals: MacroTotals
    let targets: MacroTargets?
    /// Projected totals if the day's pending entries were confirmed. When set,
    /// each chip shows a faint `+Ng` and a ghost segment on its progress capsule
    /// extending from the confirmed fill out to the projected fill. `nil` (no
    /// pending) leaves the chips unchanged.
    var projected: MacroTotals?

    var body: some View {
        HStack(spacing: 8) {
            chip(.protein, value: totals.proteinG, target: targets?.proteinG, projected: projected?.proteinG)
            chip(.carbs, value: totals.carbsG, target: targets?.carbsG, projected: projected?.carbsG)
            chip(.fat, value: totals.fatG, target: targets?.fatG, projected: projected?.fatG)
        }
    }

    /// One macro chip with grams, optional target, optional pending projection,
    /// and a thin progress capsule.
    /// Inputs:
    ///   - macro: which macro determines color and label.
    ///   - value: current (confirmed) grams.
    ///   - target: optional target grams; drives the progress fraction and `/N` suffix.
    ///   - projected: optional projected grams (confirmed + pending); drives the
    ///     `+Ng` annotation and the ghost capsule segment.
    /// Outputs: composed chip view.
    private func chip(_ macro: Theme.Macro, value: Double, target: Double?, projected: Double?) -> some View {
        let v = Int(value.rounded())
        let pct = fraction(value, of: target)
        let projectedPct = projected.map { fraction($0, of: target) } ?? 0
        let pendingDelta: Int? = {
            guard let projected, projected > value + 0.5 else { return nil }
            return Int((projected - value).rounded())
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(macro.color)
                    .frame(width: 8, height: 8)
                    .shadow(color: macro.color.opacity(0.8), radius: 4)
                Text(macro.label)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.FG.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(v)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.FG.primary)
                Text("g")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.FG.tertiary)
                if let pendingDelta {
                    Text("+\(pendingDelta)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Theme.pending)
                }
                Spacer(minLength: 0)
                if let target {
                    Text("/\(Int(target.rounded()))")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Theme.FG.tertiary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.CTP.surface1.opacity(0.45))
                    if projectedPct > pct {
                        Capsule()
                            .fill(Theme.projected.opacity(0.5))
                            .frame(width: geo.size.width * projectedPct)
                    }
                    Capsule()
                        .fill(macro.color)
                        .frame(width: geo.size.width * pct)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ctpCard()
    }

    /// Clamped 0...1 fraction of `value` against an optional target.
    /// Inputs:
    ///   - value: the grams to measure.
    ///   - target: optional target grams; a non-positive or nil target yields 0.
    /// Outputs: the progress fraction in 0...1.
    private func fraction(_ value: Double, of target: Double?) -> Double {
        guard let target, target > 0 else { return 0 }
        return min(1.0, value / target)
    }
}

#Preview {
    MacroTotalsRow(
        totals: MacroTotals(calories: 1240, proteinG: 92, carbsG: 138, fatG: 42),
        targets: MacroTargets(calories: 2200, proteinG: 150, carbsG: 250, fatG: 70, targetWeightLb: nil)
    )
    .padding()
    .background(Theme.BG.primary)
    .preferredColorScheme(.dark)
}
