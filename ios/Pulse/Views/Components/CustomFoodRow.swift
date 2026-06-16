/// List row for a saved custom food shown in the Food tab's "Foods" section.
/// Displays the food's name, a basis caption (e.g. "Per serving · 1 scoop"),
/// per-basis kcal in mauve, a P/C/F summary, and a trailing chevron. Mirrors
/// `MealRow`.
import SwiftUI

/// Row view for one custom food.
struct CustomFoodRow: View {
    let food: CustomFood

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(food.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.FG.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.FG.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(food.calories)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.CTP.mauve)
                    Text("cal")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.FG.tertiary)
                }
                Text(macroSummary)
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.FG.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.FG.tertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// Basis caption: a human basis label plus the serving descriptor when known
    /// (e.g. "Per serving · 1 scoop", "Per 100 g").
    /// Outputs: the subtitle string shown under the food name.
    private var subtitle: String {
        switch food.basis {
        case .per100g:
            return "Per 100 g"
        case .perServing:
            if let size = food.servingSize, let unit = food.servingSizeUnit {
                return "Per serving · \(NumericInput.formatBare(size)) \(unit)"
            }
            return "Per serving"
        case .perUnit:
            return "Per unit"
        }
    }

    /// Compact `P… · C… · F…` macro summary string with rounded grams.
    /// Outputs: monospaced summary string for the trailing column.
    private var macroSummary: String {
        MacroTotals.pcfSummary(proteinG: food.proteinG, carbsG: food.carbsG, fatG: food.fatG)
    }
}
