/// Saved-meal detail screen.
/// Loads the full `Meal` via `MealDetailModel` from the summary the user tapped in
/// the Food tab's Meals section (`FoodTabView`), then renders totals (hero card +
/// macro distribution + chips) plus
/// the ingredients list. Also defines the private `QuantityBadge` pill.
import SwiftUI

/// Detail screen for a single saved meal: totals card + ingredients list.
/// Triggers a `MealDetailModel` load on appear and on pull-to-refresh.
struct MealDetailView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let summary: MealSummary
    /// Called after a rename or item mutation so the host can refresh the list.
    var onMutated: () -> Void = {}
    /// Called after a successful delete with the deleted meal's id.
    var onDeleted: (UUID) -> Void = { _ in }
    @State private var model: MealDetailModel?
    @State private var showLogSheet = false
    @State private var isEditing = false
    @State private var nameDraft = ""
    @State private var showDeleteConfirm = false
    @State private var addingItem = false
    @State private var editingItem: MealItem?
    @State private var searchModel: FoodSearchModel?
    @State private var containers: [Container] = []

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
        .task(id: summary.id) {
            model = MealDetailModel(mealId: summary.id, auth: auth)
            searchModel = FoodSearchModel(auth: auth)
            await model?.load()
            // Containers are needed by the quantity step (tare lookup). Best-effort.
            containers = (try? await auth.makeClient()?.listContainers()) ?? []
        }
        .refreshable { await model?.load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if case .loaded = model?.state {
                    Button(isEditing ? "Done" : "Edit") {
                        if isEditing {
                            isEditing = false
                        } else {
                            nameDraft = summary.name
                            model?.resetEditState()
                            isEditing = true
                        }
                    }
                    .foregroundStyle(Theme.CTP.mauve)
                }
            }
        }
        .sheet(isPresented: $addingItem) {
            if let searchModel {
                FoodSearchSheet(model: searchModel, containers: containers) { batchItem in
                    Task {
                        let item = NewMealItem.from(batchItem: batchItem, containers: containers)
                        if await model?.addItem(item) == true { onMutated() }
                    }
                }
            }
        }
        .sheet(item: $editingItem) { item in
            if let result = FoodSearchResult(mealItem: item) {
                QuantityEntryView(result: result, containers: containers) { batchItem in
                    Task {
                        let rebuilt = NewMealItem.from(batchItem: batchItem, containers: containers)
                        if await model?.updateItem(itemId: item.id, to: rebuilt) == true { onMutated() }
                    }
                }
            }
        }
        .confirmationDialog("Delete this meal?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete meal", role: .destructive) {
                Task {
                    if await model?.deleteMeal() == true {
                        onDeleted(summary.id)
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showLogSheet) {
            if let model {
                MealLogSheet(model: model, mealName: summary.name)
            }
        }
    }

    /// Body for the loaded state: hero card + ingredients section.
    /// Inputs:
    ///   - meal: the fully loaded `Meal`.
    /// Outputs: composed scrollable view.
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
                    if isEditing {
                        addItemButton
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                    }
                } else {
                    ingredientsCard(meal.items)
                        .padding(.horizontal, 16)
                    if isEditing {
                        addItemButton
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                    } else {
                        logButton(disabled: false)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                    }
                }
                editErrorRow
                if isEditing {
                    deleteMealButton
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.top, 6)
        }
    }

    /// Primary "Log meal" button that presents the backdating log sheet.
    /// Inputs:
    ///   - disabled: when true, the button is dimmed and non-interactive.
    /// Outputs: composed button view.
    private func logButton(disabled: Bool) -> some View {
        PrimaryActionButton(
            title: "Log meal",
            leading: .icon("plus.circle.fill"),
            disabled: disabled
        ) {
            model?.resetLogState()
            showLogSheet = true
        }
    }

    /// "Add item" button shown in edit mode; presents the food search sheet.
    private var addItemButton: some View {
        PrimaryActionButton(title: "Add item", leading: .icon("plus"), disabled: false) {
            searchModel?.query = ""
            addingItem = true
        }
    }

    /// Destructive "Delete meal" button shown in edit mode.
    private var deleteMealButton: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label("Delete meal", systemImage: "trash")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(Theme.CTP.red)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.CTP.red.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    /// Commits the rename draft if it changed and is non-empty.
    /// Outputs: nothing; fires the model rename + `onMutated` on success.
    private func commitRename() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != summary.name else { return }
        Task { if await model?.rename(to: trimmed) == true { onMutated() } }
    }

    /// Inline error line for the most recent edit action (e.g. 409 name clash).
    /// Outputs: a red label, or empty when there is no error.
    @ViewBuilder
    private var editErrorRow: some View {
        if case .failed(let error) = model?.editState {
            Label(error.userMessage, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.CTP.red)
                .padding(.horizontal, 20)
        }
    }

    /// Top card showing meal totals, notes, macro distribution bar, and per-macro chips.
    /// Inputs:
    ///   - meal: the loaded `Meal`.
    /// Outputs: composed hero card view.
    private func heroCard(meal: Meal) -> some View {
        let totals = meal.totals
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    if isEditing {
                        TextField("Meal name", text: $nameDraft)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.FG.primary)
                            .tint(Theme.CTP.mauve)
                            .submitLabel(.done)
                            .onSubmit { commitRename() }
                    }
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

    /// Card listing the meal's ingredient rows separated by thin dividers.
    /// Inputs:
    ///   - items: the meal's `MealItem`s.
    /// Outputs: composed card view.
    private func ingredientsCard(_ items: [MealItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                let canEditQuantity = FoodSearchResult(mealItem: item) != nil
                HStack(spacing: 8) {
                    ingredientRow(item)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard isEditing, canEditQuantity else { return }
                            model?.resetEditState()
                            editingItem = item
                        }
                    if isEditing {
                        Button(role: .destructive) {
                            Task { if await model?.deleteItem(itemId: item.id) == true { onMutated() } }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.CTP.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if idx < items.count - 1 {
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                }
            }
        }
        .padding(.horizontal, 14)
        .ctpCard()
    }

    /// One ingredient row: name + per-macro grams + quantity pill + kcal.
    /// Inputs:
    ///   - item: the meal's ingredient.
    /// Outputs: composed row view.
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

/// Modal sheet for logging a saved meal against a chosen day. Wraps the shared
/// `BackdateSelector` and a confirm button that calls `MealDetailModel.logMeal`,
/// then reports progress / success / failure inline and auto-dismisses on success.
struct MealLogSheet: View {
    @Bindable var model: MealDetailModel
    let mealName: String
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date = Date()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.primary.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    Text("When did you have this?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.FG.secondary)

                    BackdateSelector(date: $date)
                        .padding(14)
                        .ctpCard()

                    statusRow

                    Spacer()

                    confirmButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .navigationTitle("Log \(mealName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.primary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
        }
    }

    /// Inline status line reflecting the model's `logState` (error feedback only;
    /// success dismisses the sheet from the confirm action's completion).
    @ViewBuilder
    private var statusRow: some View {
        switch model.logState {
        case .failed(let error):
            Label(error.userMessage, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.CTP.red)
        default:
            EmptyView()
        }
    }

    /// Confirm button that triggers the log action; shows a spinner while logging
    /// and dismisses the sheet once the meal is logged.
    private var confirmButton: some View {
        let isLogging = model.logState == .logging
        return PrimaryActionButton(
            title: isLogging ? "Logging…" : "Log meal",
            leading: .busy(isLogging),
            disabled: isLogging
        ) {
            Task {
                await model.logMeal(consumedAt: date)
                if case .logged = model.logState {
                    await model.load()
                    dismiss()
                }
            }
        }
    }
}
