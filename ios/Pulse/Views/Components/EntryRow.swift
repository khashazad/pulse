/// List row for a single `FoodEntry`.
/// Shows display name, quantity text, kcal in mauve accent, and a per-macro grams line.
import SwiftUI

/// One row in the day's entries list rendering a `FoodEntry`.
struct EntryRow: View {
    let entry: FoodEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.FG.primary)
                    Text(entry.quantityText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.FG.secondary)
                }
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(entry.calories)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.CTP.mauve)
                    Text("cal")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.FG.tertiary)
                }
            }

            HStack(spacing: 14) {
                MacroLineView(macro: .protein, grams: entry.proteinG)
                MacroLineView(macro: .carbs,   grams: entry.carbsG)
                MacroLineView(macro: .fat,     grams: entry.fatG)
            }
            .font(.system(size: 11, design: .monospaced))
        }
        .padding(.vertical, 10)
    }
}

#Preview {
    VStack(spacing: 0) {
        EntryRow(entry: FoodEntry(
            id: UUID(), dailyLogId: UUID(), userKey: "khash", entryGroupId: UUID(),
            displayName: "Oats, raw", quantityText: "80 g",
            normalizedQuantityValue: 80, normalizedQuantityUnit: "g",
            usdaFdcId: nil, usdaDescription: nil, customFoodId: nil,
            calories: 320, proteinG: 10, carbsG: 54, fatG: 6,
            mealId: nil, mealName: nil,
            consumedAt: .now, createdAt: .now
        ))
        Rectangle().fill(Theme.separator).frame(height: 0.5)
        EntryRow(entry: FoodEntry(
            id: UUID(), dailyLogId: UUID(), userKey: "khash", entryGroupId: UUID(),
            displayName: "Greek yogurt", quantityText: "200 g",
            normalizedQuantityValue: 200, normalizedQuantityUnit: "g",
            usdaFdcId: nil, usdaDescription: nil, customFoodId: nil,
            calories: 130, proteinG: 18, carbsG: 9, fatG: 4,
            mealId: nil, mealName: nil,
            consumedAt: .now, createdAt: .now
        ))
    }
    .padding(.horizontal, 14)
    .ctpCard()
    .padding()
    .background(Theme.BG.primary)
    .preferredColorScheme(.dark)
}
