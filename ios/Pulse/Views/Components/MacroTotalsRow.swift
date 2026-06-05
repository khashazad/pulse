/// Row of three macro chips (P/C/F) shown under the kcal ring or meal hero card.
/// Each chip shows current grams, optional target, and a thin progress capsule.
import SwiftUI

/// Horizontal row of protein/carbs/fat chips with optional per-macro targets.
struct MacroTotalsRow: View {
    let totals: MacroTotals
    let targets: MacroTargets?

    var body: some View {
        HStack(spacing: 8) {
            chip(.protein, value: totals.proteinG, target: targets?.proteinG)
            chip(.carbs, value: totals.carbsG, target: targets?.carbsG)
            chip(.fat, value: totals.fatG, target: targets?.fatG)
        }
    }

    /// One macro chip with grams, optional target, and thin progress capsule.
    /// Inputs:
    ///   - macro: which macro determines color and label.
    ///   - value: current grams.
    ///   - target: optional target grams; drives the progress fraction and `/N` suffix.
    /// Outputs: composed chip view.
    private func chip(_ macro: Theme.Macro, value: Double, target: Double?) -> some View {
        let v = Int(value.rounded())
        let pct: Double = {
            guard let t = target, t > 0 else { return 0 }
            return min(1.0, value / t)
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
