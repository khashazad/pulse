// Pulse/Views/SaveFoodsAsMealSheet.swift
/// Multi-step sheet for the Food tab: walks each selected custom food through
/// `QuantityEntryView` to collect a quantity, then shows the meal naming step.
/// Cancelling any quantity step (or the wizard) aborts the whole flow — nothing
/// is saved. On success it invokes `onCreated` with the new meal and dismisses.
///
/// Each quantity step is presented as its OWN nested `.sheet` rather than
/// embedded inline: `QuantityEntryView` self-dismisses after "Add", and an inline
/// embed would route that dismiss to THIS wizard's presentation and tear the
/// whole wizard down. A nested sheet keeps the dismiss scoped to one step;
/// `onDismiss` then advances the flow (on Add) or aborts it (on Cancel).
import SwiftUI

/// The Food-tab "save foods as meal" wizard.
struct SaveFoodsAsMealSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var flow: SaveFoodsAsMealFlow
    /// The food whose quantity sheet is currently presented; nil when none is up.
    @State private var activeFood: CustomFood?
    /// `flow.collected.count` captured when the active quantity sheet opened, so
    /// its dismissal can tell an "Add" (count grew) from a "Cancel" (unchanged).
    @State private var collectedAtPresent = 0
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
            .navigationTitle(flow.isComplete ? "Save as meal" : "")
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
        .onAppear { presentCurrentFoodIfNeeded() }
        .sheet(item: $activeFood, onDismiss: handleQuantityDismiss) { food in
            // Presented as its own sheet (not embedded) so QuantityEntryView's
            // self-dismiss after Add closes only this step, not the whole wizard.
            QuantityEntryView(result: FoodSearchResult(customFood: food),
                              containers: flow.containers) { item in
                flow.add(item)
            }
        }
    }

    /// Wizard backdrop behind the per-food quantity sheet: a spinner while
    /// quantities are still being collected, or the naming step once every food
    /// has one.
    /// Outputs: the backdrop or naming view for the current wizard position.
    @ViewBuilder
    private var content: some View {
        if flow.isComplete {
            WizardNamingStep(flow: flow, onCreated: onCreated, onDismiss: { dismiss() })
        } else {
            ProgressView().tint(Theme.CTP.mauve)
        }
    }

    /// Presents the current food's quantity sheet when one is pending and none is
    /// already showing, snapshotting the collected count for the dismiss handler.
    /// Outputs: nothing; sets `activeFood`/`collectedAtPresent`.
    private func presentCurrentFoodIfNeeded() {
        guard activeFood == nil, let food = flow.currentFood else { return }
        collectedAtPresent = flow.collected.count
        activeFood = food
    }

    /// Handles a quantity sheet closing. If a quantity was added (collected grew)
    /// and more foods remain, presents the next one on the following runloop
    /// (SwiftUI can't present a new sheet in the same cycle one dismisses); once
    /// every food has a quantity the naming step shows in the backdrop. If nothing
    /// was added (Cancel or swipe-away), aborts the whole wizard.
    /// Outputs: nothing; re-presents the next step or dismisses the wizard.
    private func handleQuantityDismiss() {
        guard flow.collected.count > collectedAtPresent else {
            dismiss()
            return
        }
        if !flow.isComplete {
            DispatchQueue.main.async { presentCurrentFoodIfNeeded() }
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
