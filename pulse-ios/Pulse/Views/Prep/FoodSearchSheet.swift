// Pulse/Views/Prep/FoodSearchSheet.swift
/// Food picker sheet for the Prep batch. A search field (blank until typing)
/// over "My Foods" + USDA results; tapping a result opens `QuantityEntryView`,
/// which returns a `BatchFoodItem` to the caller.
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

    var body: some View {
        NavigationStack {
            List {
                if model.usdaUnavailable {
                    Text("USDA search unavailable — showing your foods.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                switch model.state {
                case .idle:
                    Text("Search for a food").foregroundStyle(.secondary)
                case .loading:
                    ProgressView()
                case .failed:
                    Text("Couldn't search. Try again.").foregroundStyle(.secondary)
                case .loaded(let results):
                    let myFoods = results.filter { $0.source == .myFood }
                    let usda = results.filter { $0.source == .usda }
                    if results.isEmpty { Text("No matches").foregroundStyle(.secondary) }
                    if !myFoods.isEmpty {
                        Section("My Foods") { ForEach(myFoods) { row($0) } }
                    }
                    if !usda.isEmpty {
                        Section("USDA") { ForEach(usda) { row($0) } }
                    }
                }
            }
            .searchable(text: $model.query, prompt: "Search foods")
            .navigationTitle("Add food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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

    /// One tappable result row.
    /// Inputs:
    ///   - result: the food to render.
    /// Outputs: a button row that selects the food for quantity entry.
    private func row(_ result: FoodSearchResult) -> some View {
        Button { picked = result } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.displayName)
                Text("\(result.nutrition.caloriesPerBasis) kcal / \(basisLabel(result.nutrition.basis))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Human label for a basis.
    /// Inputs:
    ///   - b: the food basis.
    /// Outputs: a short unit string for display.
    private func basisLabel(_ b: FoodBasis) -> String {
        switch b {
        case .per100g: return "100g"
        case .perServing: return "serving"
        case .perUnit: return "unit"
        }
    }
}
