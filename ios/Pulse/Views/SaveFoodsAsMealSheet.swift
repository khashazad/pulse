// Pulse/Views/SaveFoodsAsMealSheet.swift
/// Multi-step sheet for the Food tab: walks each selected custom food through
/// `QuantityEntryView` to collect a quantity, then shows the meal naming step.
/// Cancelling at any point aborts the whole flow (nothing is saved). On success
/// it invokes `onCreated` with the new meal and dismisses.
import SwiftUI

/// The Food-tab "save foods as meal" wizard.
struct SaveFoodsAsMealSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var flow: SaveFoodsAsMealFlow
    /// Called once the meal is created, with the new meal.
    let onCreated: (Meal) -> Void

    /// Builds the wizard for a selection of custom foods.
    /// Inputs:
    ///   - foods: the selected standalone custom foods (non-empty).
    ///   - auth: auth session for quantity/container + create clients.
    ///   - onCreated: completion invoked with the created meal.
    /// Outputs: a configured wizard sheet.
    init(foods: [CustomFood], auth: AuthSession?, onCreated: @escaping (Meal) -> Void) {
        _flow = State(initialValue: SaveFoodsAsMealFlow(foods: foods, auth: auth))
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.primary.ignoresSafeArea()
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.primary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.FG.secondary)
                }
            }
        }
        .task { await flow.loadContainers() }
    }

    /// Either the current food's quantity step, or the final naming step.
    /// Outputs: the step view for the current wizard position.
    @ViewBuilder
    private var content: some View {
        if let food = flow.currentFood {
            // `.id(food.id)` forces a fresh QuantityEntryView per food so its
            // internal @State (mode, typed text) resets between steps.
            // NOTE: QuantityEntryView owns its own NavigationStack, so during the
            // per-food steps it nests inside this wizard's stack (two nav bars).
            // Deferred: making QuantityEntryView headless would touch its other
            // callers (CustomFoodDetailView, FoodSearchSheet) — out of scope here.
            QuantityEntryView(result: FoodSearchResult(customFood: food),
                              containers: flow.containers) { item in
                flow.add(item)
            }
            .id(food.id)
        } else {
            WizardNamingStep(flow: flow, onCreated: onCreated, onDismiss: { dismiss() })
        }
    }
}

/// Final naming step of the wizard. Owns its `SaveAsMealSheetModel` in `@State`
/// (built once from the flow's collected quantities, so it survives re-renders)
/// and reports completion up to the wizard.
private struct WizardNamingStep: View {
    @State private var model: SaveAsMealSheetModel
    /// Called with the created meal once the user saves.
    let onCreated: (Meal) -> Void
    /// Dismisses the enclosing wizard sheet.
    let onDismiss: () -> Void

    /// Builds the naming step, constructing the save model from the flow once.
    /// Inputs:
    ///   - flow: the completed wizard flow supplying the collected items.
    ///   - onCreated: invoked with the created meal on success.
    ///   - onDismiss: invoked to dismiss the wizard after success.
    /// Outputs: a configured naming-step view.
    init(flow: SaveFoodsAsMealFlow, onCreated: @escaping (Meal) -> Void, onDismiss: @escaping () -> Void) {
        _model = State(initialValue: flow.makeSaveModel())
        self.onCreated = onCreated
        self.onDismiss = onDismiss
    }

    var body: some View {
        MealNameStep(model: model)
            .navigationTitle("Save as meal")
            .onChange(of: model.created) { _, created in
                guard let created else { return }
                onCreated(created)
                onDismiss()
            }
    }
}
