/// Expandable row for a logged meal in the day's entries list.
/// Header shows meal name + item count + total kcal + summed macro line; tap toggles
/// an inline list of each underlying `FoodEntry` rendered via `EntryRow`.
import SwiftUI

/// Day-entries row representing a `MealGroup`; expands to reveal its `EntryRow`s.
struct MealGroupRow: View {
    let group: MealGroup
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                expandedItems
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - header

    private var header: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    chevron
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.displayName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.FG.primary)
                        subtitle
                    }
                    Spacer(minLength: 8)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(group.totals.calories)")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.CTP.mauve)
                        Text("cal")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.FG.tertiary)
                    }
                }

                HStack(spacing: 14) {
                    MacroLineView(macro: .protein, grams: group.totals.proteinG)
                    MacroLineView(macro: .carbs, grams: group.totals.carbsG)
                    MacroLineView(macro: .fat, grams: group.totals.fatG)
                }
                .font(.system(size: 11, design: .monospaced))
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.FG.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
    }

    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 6) {
            Text("\(group.items.count) items")
                .font(.system(size: 12))
                .foregroundStyle(Theme.FG.secondary)
            if group.count > 1 {
                Text("×\(group.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.CTP.mauve)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule().fill(Theme.CTP.mauve.opacity(0.18))
                    )
            }
        }
    }

    // MARK: - expanded items

    private var expandedItems: some View {
        VStack(spacing: 0) {
            ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                EntryRow(entry: item)
                    .padding(.leading, 12)
                if idx < group.items.count - 1 {
                    Rectangle()
                        .fill(Theme.separator.opacity(0.5))
                        .frame(height: 0.5)
                        .padding(.leading, 12)
                }
            }
        }
    }

    // MARK: - actions

    /// Animates `isExpanded` between collapsed and expanded states.
    private func toggle() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
        }
    }
}

#Preview {
    let oats = FoodEntry(
        id: UUID(), dailyLogId: UUID(), userKey: "khash", entryGroupId: UUID(),
        displayName: "Oats, raw", quantityText: "80 g",
        normalizedQuantityValue: 80, normalizedQuantityUnit: "g",
        usdaFdcId: 173904, usdaDescription: "Oats, raw", customFoodId: nil,
        calories: 320, proteinG: 10, carbsG: 54, fatG: 6,
        mealId: UUID(), mealName: "Breakfast Bowl",
        consumedAt: .now, createdAt: .now
    )
    let yogurt = FoodEntry(
        id: UUID(), dailyLogId: UUID(), userKey: "khash", entryGroupId: UUID(),
        displayName: "Greek yogurt", quantityText: "200 g",
        normalizedQuantityValue: 200, normalizedQuantityUnit: "g",
        usdaFdcId: 748967, usdaDescription: "Yogurt, Greek", customFoodId: nil,
        calories: 130, proteinG: 18, carbsG: 9, fatG: 4,
        mealId: UUID(), mealName: "Breakfast Bowl",
        consumedAt: .now, createdAt: .now
    )
    let group = MealGroup(
        id: "meal:preview",
        mealId: UUID(),
        displayName: "Breakfast Bowl",
        count: 2,
        items: [oats, yogurt],
        totals: MacroTotals(calories: 900, proteinG: 56, carbsG: 126, fatG: 20),
        sortDate: .now
    )
    return VStack(spacing: 0) {
        MealGroupRow(group: group)
    }
    .padding(.horizontal, 14)
    .ctpCard()
    .padding()
    .background(Theme.BG.primary)
    .preferredColorScheme(.dark)
}
