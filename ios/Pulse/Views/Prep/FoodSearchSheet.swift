// Pulse/Views/Prep/FoodSearchSheet.swift
/// Food picker sheet for the Prep batch. A themed, auto-focused search field
/// over "My Foods" + USDA results (the my-foods set is browseable while the
/// query is empty); tapping a result opens `QuantityEntryView`, which returns
/// a `BatchFoodItem` to the caller. Styled per the ContainerPickerSheet
/// pattern (Theme.BG.secondary sheet, Theme.BG.tertiary rows).
import SwiftUI

/// Sheet that searches foods and emits a chosen, quantified batch item.
struct FoodSearchSheet: View {
    /// Search model (owns query + results), created and retained by the caller.
    @Bindable var model: FoodSearchModel
    /// Containers for the quantity step.
    let containers: [Container]
    /// Called when the user adds a quantified food.
    let onAdd: (BatchFoodItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picked: FoodSearchResult?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.secondary.ignoresSafeArea()
                VStack(spacing: 0) {
                    searchField
                    content
                }
            }
            .navigationTitle("Add food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.secondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
            .onAppear {
                // Give the sheet's presentation one runloop turn to settle,
                // then focus — decoupled from network latency in loadMyFoods.
                Task { @MainActor in searchFocused = true }
            }
            .task { await model.loadMyFoods() }
            .sheet(item: $picked) { result in
                QuantityEntryView(result: result, containers: containers) { item in
                    onAdd(item)
                    picked = nil
                    dismiss()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Themed search input pinned above the result list (replaces `.searchable`,
    /// which rendered a second gray system bar inside the sheet).
    /// Outputs: a capsule-styled text field with icon and clear button.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(Theme.FG.tertiary)
            TextField(
                "",
                text: $model.query,
                prompt: Text("Search foods").foregroundStyle(Theme.FG.tertiary)
            )
            .font(.system(size: 15))
            .foregroundStyle(Theme.FG.primary)
            .tint(Theme.CTP.mauve)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($searchFocused)
            .accessibilityLabel("Search foods")
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.FG.tertiary)
                }
                .accessibilityLabel("Clear search")
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Capsule().fill(Theme.BG.tertiary))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Result area for the current model state.
    /// Outputs: spinner, failure state, or the sectioned result list.
    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .tint(Theme.CTP.mauve)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let e):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load foods",
                description: e.userMessage,
                action: { model.retry() },
                actionLabel: "Retry"
            )
        case .loaded(let results):
            resultList(results)
        }
    }

    /// Sectioned list of my-foods + USDA results, or an empty state.
    /// Inputs:
    ///   - results: merged results for the active query (or the browse list).
    /// Outputs: a themed `List`, or an `EmptyStateView` when nothing matches.
    @ViewBuilder
    private func resultList(_ results: [FoodSearchResult]) -> some View {
        let myFoods = results.filter { $0.source == .myFood }
        let usda = results.filter { $0.source == .usda }
        if results.isEmpty {
            // `isBrowsing` (not raw `query.isEmpty`) so whitespace-only input
            // gets browse-mode copy, matching the model's own predicate.
            EmptyStateView(
                icon: "magnifyingglass",
                title: model.isBrowsing ? "No foods yet" : "No matches",
                description: model.isBrowsing
                    ? "Foods you save or remember will show up here."
                    : "Try a different name."
            )
        } else {
            List {
                if model.usdaUnavailable {
                    Section {
                        Text("USDA search unavailable — showing your foods.")
                            .font(.footnote)
                            .foregroundStyle(Theme.FG.secondary)
                            .listRowBackground(Theme.BG.tertiary)
                    }
                }
                if !myFoods.isEmpty {
                    Section {
                        ForEach(myFoods) { row($0) }
                    } header: { sectionHeader("My Foods") }
                }
                if !usda.isEmpty {
                    Section {
                        ForEach(usda) { row($0) }
                    } header: { sectionHeader("USDA") }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    /// Muted section header text.
    /// Inputs:
    ///   - title: the section title.
    /// Outputs: a styled header `View`.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.FG.secondary)
    }

    /// One tappable result row: name, optional disambiguation badge, caption.
    /// Inputs:
    ///   - result: the food to render.
    /// Outputs: a button row that selects the food for quantity entry.
    private func row(_ result: FoodSearchResult) -> some View {
        Button { picked = result } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(result.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.FG.primary)
                    if let badge = result.badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.CTP.mauve)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.CTP.mauve.opacity(0.15)))
                            .lineLimit(1)
                    }
                }
                Text(result.caption)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.FG.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.BG.tertiary)
        .listRowSeparatorTint(Theme.separator)
    }
}
