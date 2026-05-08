import SwiftUI

struct MealDetailView: View {
    @Environment(AppSettings.self) private var settings
    let summary: MealSummary
    @State private var model: MealDetailModel?

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            Group {
                switch model?.state ?? .idle {
                case .idle, .loading:
                    ProgressView()
                        .tint(Theme.CTP.mauve)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let meal):
                    loadedBody(meal: meal)
                case .failed(let error):
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Couldn't load",
                        description: error.userMessage,
                        action: { Task { await model?.load() } },
                        actionLabel: "Retry"
                    )
                }
            }
        }
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.BG.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            if model == nil { model = MealDetailModel(mealId: summary.id, settings: settings) }
            await model?.load()
        }
        .refreshable { await model?.load() }
    }

    private func loadedBody(meal: Meal) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heroCard(meal: meal)
                    .padding(.horizontal, 16)

                Text("Ingredients")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.FG.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                if meal.items.isEmpty {
                    EmptyStateView(
                        icon: "fork.knife",
                        title: "No ingredients",
                        description: "This meal has no items yet."
                    )
                } else {
                    ingredientsCard(meal.items)
                        .padding(.horizontal, 16)
                }

                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.top, 6)
        }
    }

    private func heroCard(meal: Meal) -> some View {
        let totals = meal.totals
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.FG.secondary)
                    if let notes = meal.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.FG.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(totals.calories)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.FG.primary)
                    Text("cal")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.FG.tertiary)
                }
            }
            MacroDistributionBar(
                proteinG: totals.proteinG,
                carbsG: totals.carbsG,
                fatG: totals.fatG
            )
            MacroTotalsRow(totals: totals, targets: nil)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .ctpCard()
    }

    private func ingredientsCard(_ items: [MealItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                ingredientRow(item)
                if idx < items.count - 1 {
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                }
            }
        }
        .padding(.horizontal, 14)
        .ctpCard()
    }

    private func ingredientRow(_ item: MealItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.FG.primary)
                    .lineLimit(1)
                Text("P\(Int(item.proteinG.rounded())) · C\(Int(item.carbsG.rounded())) · F\(Int(item.fatG.rounded()))")
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.FG.tertiary)
            }
            Spacer(minLength: 6)
            QuantityBadge(text: item.quantityText)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(item.calories)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.CTP.mauve)
                Text("cal")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.FG.tertiary)
            }
            .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.vertical, 11)
    }
}

/// Mono pill that displays the server's already-formatted `quantity_text` (e.g. "80 g", "1 medium").
private struct QuantityBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Theme.FG.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.CTP.surface0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 0.5)
            )
    }
}
