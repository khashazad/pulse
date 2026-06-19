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

/// Identifiable payload that drives the grouping sheet (the selected standalones).
private struct GroupingRequest: Identifiable {
    let id = UUID()
    let foods: [CustomFood]
}

/// Identifiable payload that drives the grouping-suggestions chooser sheet.
private struct SuggestionsRequest: Identifiable {
    let id = UUID()
    let clusters: [[CustomFood]]
}

/// Identifiable payload that drives the "save foods as meal" wizard.
private struct SaveMealRequest: Identifiable {
    let id = UUID()
    let foods: [CustomFood]
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
    /// Auth session used to build the create client for the grouping sheet.
    let auth: AuthSession

    @State private var section: FoodSection = .meals
    @State private var query = ""
    // Expansion persists across query changes by design: a row the user expanded
    // reappears still-expanded after a filtering query is cleared.
    @State private var expanded: Set<UUID> = []
    // Grouping-selection mode over standalone foods.
    @State private var isSelecting = false
    @State private var selected: Set<UUID> = []
    @State private var grouping: GroupingRequest?
    // Drives the "browse all merge suggestions" chooser sheet.
    @State private var suggestions: SuggestionsRequest?
    // Drives the "save selected foods as meal" quantity wizard.
    @State private var savingFoodsAsMeal: SaveMealRequest?
    /// Name of a just-saved meal, shown as a transient confirmation; nil hides it.
    @State private var savedMealName: String?
    // The food pending an ungroup confirmation, if any.
    @State private var ungroupTarget: Food?

    /// Toggles a grouped food's expansion in the browse list.
    /// Inputs:
    ///   - id: the food's UUID.
    /// Outputs: nothing; mutates `expanded`.
    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Toggles selection of a standalone food during grouping-selection mode.
    /// Inputs:
    ///   - id: the standalone custom food's UUID.
    /// Outputs: nothing; mutates `selected`.
    private func toggleSelect(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
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
        .sheet(item: $grouping) { request in
            GroupFoodSheet(foods: request.foods, auth: auth) { newFood, ids in
                foodsModel.applyGrouped(newFood, groupedIds: ids)
                isSelecting = false
                selected = []
            }
        }
        .sheet(item: $suggestions) { request in
            GroupSuggestionsSheet(clusters: request.clusters) { cluster in
                isSelecting = true
                selected = Set(cluster.map(\.id))
            }
        }
        .sheet(item: $savingFoodsAsMeal) { request in
            SaveFoodsAsMealSheet(foods: request.foods, auth: auth) { meal in
                isSelecting = false
                selected = []
                savedMealName = meal.name
                Task { await mealsModel.load() }
            }
        }
        .overlay(alignment: .bottom) {
            if let name = savedMealName {
                Text("Saved “\(name)”")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.FG.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(Theme.BG.secondary)
                            .overlay(Capsule().stroke(Theme.separator, lineWidth: 0.5)))
                    .padding(.bottom, Theme.Layout.dockClearance)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        withAnimation { savedMealName = nil }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: savedMealName)
        .confirmationDialog(
            ungroupTarget.map { "Ungroup \($0.name)?" } ?? "",
            isPresented: Binding(get: { ungroupTarget != nil },
                                 set: { if !$0 { ungroupTarget = nil } }),
            titleVisibility: .visible,
            presenting: ungroupTarget
        ) { food in
            Button("Ungroup", role: .destructive) {
                Task { await foodsModel.ungroup(food) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { food in
            Text("Its \(food.portions.count) portions become separate foods again. Your logs are unaffected.")
        }
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
                ScrollView {
                    // Show the controls only when there's something to act on — while
                    // selecting, or when standalones survive the current query — so a
                    // query that filters all standalones away leaves no phantom gap.
                    if isSelecting || !standalones.isEmpty {
                        foodsControls(allStandalones: browse.standalones)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(foods.enumerated()), id: \.element.id) { idx, food in
                            FoodGroupRow(
                                food: food,
                                isExpanded: expanded.contains(food.id),
                                onToggle: { toggle(food.id) },
                                onSelectPortion: { onOpenPortion($0) },
                                onUngroup: { ungroupTarget = food }
                            )
                            .opacity(isSelecting ? 0.4 : 1)
                            .disabled(isSelecting)
                            if idx < foods.count - 1 || !standalones.isEmpty { divider }
                        }
                        ForEach(Array(standalones.enumerated()), id: \.element.id) { idx, food in
                            standaloneRow(food)
                            if idx < standalones.count - 1 { divider }
                        }
                    }
                    .padding(.horizontal, 14)
                    .ctpCard()
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    Spacer(minLength: Theme.Layout.dockClearance)
                }
            }
        case .failed(let error):
            EmptyStateView(icon: "exclamationmark.triangle", title: "Couldn't load",
                           description: error.userMessage,
                           action: { Task { await foodsModel.load() } }, actionLabel: "Retry")
        }
    }

    /// The controls above the foods list: the Select/Done toggle, the
    /// "group N into food" action while selecting, and the duplicates hint.
    /// The caller only renders this while selecting or when standalones are
    /// visible, so the Select/Done button is always appropriate here.
    /// Inputs:
    ///   - allStandalones: the full standalone list (selection resolves against it).
    /// Outputs: the composed controls view.
    @ViewBuilder
    private func foodsControls(allStandalones: [CustomFood]) -> some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Button(isSelecting ? "Done" : "Select") {
                    isSelecting.toggle()
                    if !isSelecting { selected = [] }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.CTP.mauve)
            }
            if isSelecting, selected.count >= 1 {
                let chosen = allStandalones.filter { selected.contains($0.id) }
                if chosen.count >= 2 {
                    PrimaryActionButton(title: "Group \(chosen.count) into food",
                                        leading: .icon("rectangle.3.group"), disabled: false) {
                        grouping = GroupingRequest(foods: chosen)
                    }
                }
                PrimaryActionButton(title: "Save \(chosen.count) as meal",
                                    leading: .icon("square.stack.3d.up"), disabled: false) {
                    savingFoodsAsMeal = SaveMealRequest(foods: chosen)
                }
            }
            if !isSelecting, !foodsModel.duplicateClusters.isEmpty {
                duplicateHint(clusters: foodsModel.duplicateClusters)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// A tappable hint surfacing likely grouping candidates. With a single
    /// cluster, tapping enters selection mode with it pre-selected; with several,
    /// tapping opens the chooser sheet so the user can pick which to merge.
    /// Inputs:
    ///   - clusters: the duplicate clusters found among standalones (non-empty).
    /// Outputs: the composed hint banner.
    private func duplicateHint(clusters: [[CustomFood]]) -> some View {
        Button {
            if clusters.count == 1 {
                isSelecting = true
                selected = Set(clusters[0].map(\.id))
            } else {
                suggestions = SuggestionsRequest(clusters: clusters)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                Text("\(clusters.count) possible \(clusters.count == 1 ? "group" : "groups") to merge")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.CTP.mauve)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.Layout.cardRadius, style: .continuous)
                    .fill(Theme.CTP.mauve.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    /// One standalone food row: a selection toggle while selecting, otherwise a
    /// tap that opens its detail screen.
    /// Inputs:
    ///   - food: the standalone custom food to render.
    /// Outputs: the composed row view.
    private func standaloneRow(_ food: CustomFood) -> some View {
        Button {
            if isSelecting { toggleSelect(food.id) } else { onOpenFood(food) }
        } label: {
            HStack(spacing: 10) {
                if isSelecting {
                    Image(systemName: selected.contains(food.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(selected.contains(food.id) ? Theme.CTP.mauve : Theme.FG.tertiary)
                }
                CustomFoodRow(food: food)
            }
        }
        .buttonStyle(.plain)
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
