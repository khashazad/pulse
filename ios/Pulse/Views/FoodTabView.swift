/// Root screen of the Food tab. Hosts two sections behind a segmented toggle —
/// saved Meals and saved custom Foods — with a single shared `.searchable` field
/// that filters whichever section is active (client-side, by name). Meals open
/// `MealDetailView`; foods open `CustomFoodDetailView`. Replaces the old
/// `MealsView`. The list models are owned by `RootView` and injected so the
/// pushed detail screens share one instance.
import SwiftUI

/// The two sections the Food tab can show.
private enum FoodSection: String, CaseIterable, Identifiable {
    case meals = "Meals"
    case foods = "Foods"
    var id: String { rawValue }
}

/// Food-tab root: section toggle + shared search over meals and custom foods.
struct FoodTabView: View {
    let mealsModel: MealsModel
    let foodsModel: FoodsModel
    /// Forwards a tapped meal to the host (`RootView`) for navigation.
    let onOpenMeal: (MealSummary) -> Void
    /// Forwards a tapped standalone custom food to the host (`RootView`) for navigation.
    let onOpenFood: (CustomFood) -> Void
    /// Forwards a tapped portion's custom-food id to the host, which resolves it
    /// back to a full `CustomFood` and pushes the detail screen.
    let onOpenPortion: (UUID) -> Void

    @State private var section: FoodSection = .meals
    @State private var query = ""
    // Expansion persists across query changes by design: a row the user expanded
    // reappears still-expanded after a filtering query is cleared.
    @State private var expanded: Set<UUID> = []

    /// Toggles a grouped food's expansion in the browse list.
    /// Inputs:
    ///   - id: the food's UUID.
    /// Outputs: nothing; mutates `expanded`.
    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// The screen body: section picker, the active section's content, and the
    /// shared search field, with on-appear / pull-to-refresh loading of both models.
    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    ForEach(FoodSection.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                Group {
                    switch section {
                    case .meals: mealsSection
                    case .foods: foodsSection
                    }
                }
            }
        }
        .navigationTitle("Food")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.BG.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: section == .meals ? "Search meals" : "Search foods")
        .task { await loadBoth() }
        .refreshable { await loadBoth() }
    }

    /// Loads both sections concurrently so a cold tab open (or pull-to-refresh)
    /// isn't gated on one fetch then the other — they're independent.
    /// Outputs: nothing; each model reflects its own result in `state`.
    private func loadBoth() async {
        async let meals: Void = mealsModel.load()
        async let foods: Void = foodsModel.load()
        _ = await (meals, foods)
    }

    // MARK: - Meals section

    /// Meals section: loading / failed / empty / list states from `MealsModel`.
    @ViewBuilder
    private var mealsSection: some View {
        switch mealsModel.state {
        case .idle, .loading:
            loading
        case .loaded(let meals):
            let filtered = FoodTabFilter.meals(meals, query: query)
            if filtered.isEmpty {
                EmptyStateView(icon: "fork.knife", title: query.isEmpty ? "No meals saved" : "No matches",
                               description: query.isEmpty ? "Meals you save will appear here." : "No meals match \"\(query)\".")
            } else {
                listCard {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, meal in
                        Button { onOpenMeal(meal) } label: { MealRow(summary: meal) }
                            .buttonStyle(.plain)
                        if idx < filtered.count - 1 { divider }
                    }
                }
            }
        case .failed(let error):
            EmptyStateView(icon: "exclamationmark.triangle", title: "Couldn't load",
                           description: error.userMessage,
                           action: { Task { await mealsModel.load() } }, actionLabel: "Retry")
        }
    }

    // MARK: - Foods section

    /// Foods section: loading / failed / empty / list states from `FoodsModel`.
    /// Grouped foods render first as collapsible rows, then ungrouped standalones.
    @ViewBuilder
    private var foodsSection: some View {
        switch foodsModel.state {
        case .idle, .loading:
            loading
        case .loaded(let browse):
            // Grouped foods keep the server's order (it sorts by normalized_name),
            // so we only name-filter here; standalones are re-sorted by FoodTabFilter.foods.
            let foods = browse.foods.filter { FoodTabFilter.matches($0.name, query: query) }
            let standalones = FoodTabFilter.foods(browse.standalones, query: query)
            if foods.isEmpty && standalones.isEmpty {
                EmptyStateView(icon: "carrot",
                               title: query.isEmpty ? "No saved foods" : "No matches",
                               description: query.isEmpty ? "Custom foods you save will appear here." : "No foods match \"\(query)\".")
            } else {
                listCard {
                    ForEach(Array(foods.enumerated()), id: \.element.id) { idx, food in
                        FoodGroupRow(
                            food: food,
                            isExpanded: expanded.contains(food.id),
                            onToggle: { toggle(food.id) },
                            onSelectPortion: { onOpenPortion($0) }
                        )
                        if idx < foods.count - 1 || !standalones.isEmpty { divider }
                    }
                    ForEach(Array(standalones.enumerated()), id: \.element.id) { idx, food in
                        Button { onOpenFood(food) } label: { CustomFoodRow(food: food) }
                            .buttonStyle(.plain)
                        if idx < standalones.count - 1 { divider }
                    }
                }
            }
        case .failed(let error):
            EmptyStateView(icon: "exclamationmark.triangle", title: "Couldn't load",
                           description: error.userMessage,
                           action: { Task { await foodsModel.load() } }, actionLabel: "Retry")
        }
    }

    // MARK: - Shared pieces

    /// Centered loading spinner used by both sections.
    private var loading: some View {
        ProgressView().tint(Theme.CTP.mauve).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Hairline row divider used between list rows.
    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(height: 0.5)
    }

    /// Wraps section rows in the standard scrollable card layout.
    /// Inputs:
    ///   - rows: the row content to place inside the card.
    /// Outputs: composed scrollable card view.
    private func listCard<Content: View>(@ViewBuilder rows: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 0) { rows() }
                .padding(.horizontal, 14)
                .ctpCard()
                .padding(.horizontal, 16)
                .padding(.top, 8)
            Spacer(minLength: Theme.Layout.dockClearance)
        }
    }
}
