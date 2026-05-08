import SwiftUI

/// Variant A row — name + notes + ingredient count, kcal in mauve, P/C/F summary, chevron.
struct MealRow: View {
    let summary: MealSummary

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.name)
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
                    Text("\(summary.totalCalories)")
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

    private var subtitle: String {
        let count = summary.itemCount
        let countText = "\(count) \(count == 1 ? "ingredient" : "ingredients")"
        if let notes = summary.notes, !notes.isEmpty {
            return "\(notes) · \(countText)"
        }
        return countText
    }

    private var macroSummary: String {
        let p = Int(summary.totalProteinG.rounded())
        let c = Int(summary.totalCarbsG.rounded())
        let f = Int(summary.totalFatG.rounded())
        return "P\(p) · C\(c) · F\(f)"
    }
}
