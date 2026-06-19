// Pulse/State/SaveFoodsAsMealFlow.swift
/// Coordinator for the Food-tab "save foods as meal" wizard: walks the selected
/// custom foods one at a time, collecting a quantity (`BatchFoodItem`) for each,
/// then exposes the assembled meal items. Lazily loads the user's containers so
/// the quantity step can offer weighing. Cancelling the sheet discards the whole
/// flow (the host just dismisses; nothing is persisted here).
import Foundation
import Observation

/// Observable wizard state over a fixed list of foods.
@Observable
final class SaveFoodsAsMealFlow: Identifiable {
    let id = UUID()
    /// The foods to walk through, in order.
    let foods: [CustomFood]
    /// Containers available for the weigh path (best-effort; may stay empty).
    private(set) var containers: [Container] = []
    /// Quantities collected so far, one per advanced food.
    private(set) var collected: [BatchFoodItem] = []
    private weak var auth: AuthSession?

    /// Builds the flow over a selection of custom foods.
    /// Inputs:
    ///   - foods: the selected standalone custom foods (non-empty).
    ///   - auth: auth session for the create + container-load clients.
    /// Outputs: a configured flow positioned at the first food.
    init(foods: [CustomFood], auth: AuthSession?) {
        self.foods = foods
        self.auth = auth
    }

    /// The food currently awaiting a quantity, or nil once all are collected.
    /// Outputs: the next food to quantify, or nil when complete.
    var currentFood: CustomFood? {
        collected.count < foods.count ? foods[collected.count] : nil
    }

    /// Whether every food has a collected quantity.
    /// Outputs: true once one quantity exists per food.
    var isComplete: Bool { collected.count == foods.count }

    /// Records a quantity for the current food and advances.
    /// Inputs:
    ///   - item: the `BatchFoodItem` produced by the quantity step.
    /// Outputs: nothing; appends to `collected`.
    func add(_ item: BatchFoodItem) {
        guard !isComplete else { return }
        collected.append(item)
    }

    /// Best-effort load of the user's containers for the weigh path. No-op once
    /// loaded or when there is no signed-in client.
    /// Outputs: nothing; populates `containers` on success.
    func loadContainers() async {
        guard containers.isEmpty, let client = auth?.makeClient() else { return }
        if let list = try? await client.listContainers() { containers = list }
    }

    /// The collected quantities mapped to meal items (tare netted via containers).
    /// Outputs: one `NewMealItem` per collected food, in order.
    var mealItems: [NewMealItem] {
        collected.map { NewMealItem.from(batchItem: $0, containers: containers) }
    }

    /// Builds the naming-step model from the collected items, pre-filling the
    /// meal name from the shared stem of the grouped foods.
    /// Outputs: a `SaveAsMealSheetModel` over `mealItems`.
    func makeSaveModel() -> SaveAsMealSheetModel {
        SaveAsMealSheetModel(items: mealItems,
                             suggestedName: FoodDuplicateGrouper.suggestedName(for: foods),
                             auth: auth)
    }
}
