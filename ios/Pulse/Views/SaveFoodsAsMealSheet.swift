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
    /// The naming step's model, built once all quantities are collected.
    @State private var saveModel: SaveAsMealSheetModel?
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
            QuantityEntryView(result: FoodSearchResult(customFood: food),
                              containers: flow.containers) { item in
                flow.add(item)
            }
            .id(food.id)
        } else {
            namingStep
        }
    }

    /// The naming step, lazily building the save model once on first appearance.
    /// Outputs: the meal-naming step view.
    @ViewBuilder
    private var namingStep: some View {
        Group {
            if let saveModel {
                MealNameStep(model: saveModel)
                    .navigationTitle("Save as meal")
                    .onChange(of: saveModel.created) { _, created in
                        guard let created else { return }
                        onCreated(created)
                        dismiss()
                    }
            } else {
                Color.clear
            }
        }
        .onAppear {
            if saveModel == nil {
                saveModel = flow.makeSaveModel(
                    suggestedName: FoodDuplicateGrouper.suggestedName(for: flow.foods))
            }
        }
    }
}
