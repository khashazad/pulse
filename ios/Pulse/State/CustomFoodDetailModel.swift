// Pulse/State/CustomFoodDetailModel.swift
/// CustomFoodDetailModel: view-model for one custom food's detail screen. Owns
/// the (locally mutable) food plus three independent action states — rename,
/// delete, and log-to-today — and lazily loads the user's containers so the log
/// flow can offer weighing. Mirrors `MealDetailModel`'s state-machine shape.
import Foundation
import Observation

/// Observable detail model for a single custom food.
@Observable
final class CustomFoodDetailModel {
    /// The current food; updated in place after a successful rename.
    private(set) var food: CustomFood
    /// Containers available for the log flow's weigh mode (empty until loaded).
    private(set) var containers: [Container] = []

    private(set) var renameState: RenameState = .idle
    private(set) var deleteState: DeleteState = .idle
    private(set) var logState: LogState = .idle

    private weak var auth: AuthSession?

    /// Rename action lifecycle.
    enum RenameState: Equatable { case idle, saving, saved, failed(PulseError) }
    /// Delete action lifecycle.
    enum DeleteState: Equatable { case idle, deleting, deleted, failed(PulseError) }
    /// Log action lifecycle; `logged` carries the affected day's recomputed totals.
    enum LogState: Equatable { case idle, logging, logged(MacroTotals), failed(PulseError) }

    /// Initializes the detail model.
    /// Inputs:
    ///   - food: the custom food the user tapped.
    ///   - auth: auth session used to build an authenticated client.
    /// Outputs: a configured model in the `.idle` state for all three actions.
    init(food: CustomFood, auth: AuthSession) {
        self.food = food
        self.auth = auth
    }

    /// A `FoodSearchResult` view of this food, used to feed the shared
    /// `QuantityEntryView` and to build the basis-context line on the detail card.
    /// Outputs: the source-agnostic search result wrapping this custom food.
    var asSearchResult: FoodSearchResult { FoodSearchResult(customFood: food) }

    /// Loads the user's containers for the log flow's weigh mode. Best-effort:
    /// a failure leaves `containers` empty (type-only logging still works).
    /// Outputs: nothing; populates `containers` on success.
    func loadContainers() async {
        guard let client = auth?.makeClient() else { return }
        if let list = try? await client.listContainers() { containers = list }
    }

    /// Renames the food via the API and applies the result locally on success.
    /// Inputs:
    ///   - newName: the requested new name (already trimmed by the caller).
    /// Outputs: nothing; result reflected in `renameState` and `food`.
    func rename(to newName: String) async {
        guard let client = auth?.makeClient() else { renameState = .failed(.notSignedIn); return }
        renameState = .saving
        do {
            let updated = try await client.updateCustomFood(id: food.id, name: newName)
            food = updated
            renameState = .saved
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            renameState = .failed(error)
        } catch {
            renameState = .failed(.server(status: -1))
        }
    }

    /// Deletes the food via the API.
    /// Outputs: nothing; result reflected in `deleteState`.
    func delete() async {
        guard let client = auth?.makeClient() else { deleteState = .failed(.notSignedIn); return }
        deleteState = .deleting
        do {
            try await client.deleteCustomFood(id: food.id)
            deleteState = .deleted
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            deleteState = .failed(error)
        } catch {
            deleteState = .failed(.server(status: -1))
        }
    }

    /// Logs a chosen quantity of this food to today (server "now"). Builds a
    /// custom-food entry from the quantity sheet's result and posts it.
    /// Inputs:
    ///   - item: the `BatchFoodItem` produced by `QuantityEntryView`.
    /// Outputs: nothing; result reflected in `logState`.
    func log(_ item: BatchFoodItem) async {
        guard let client = auth?.makeClient() else { logState = .failed(.notSignedIn); return }
        guard let customId = item.customFoodId else { logState = .failed(.server(status: -1)); return }
        logState = .logging
        let payload = FoodEntryCreate.custom(
            displayName: item.displayName,
            quantityText: quantityText(for: item),
            customFoodId: customId,
            calories: item.macros.calories,
            proteinG: item.macros.proteinG,
            carbsG: item.macros.carbsG,
            fatG: item.macros.fatG,
            consumedAt: nil
        )
        do {
            let response = try await client.createEntries([payload])
            logState = .logged(response.dailyTotals)
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            logState = .failed(error)
        } catch {
            logState = .failed(.server(status: -1))
        }
    }

    /// Resets the log action to idle so stale success/failure state doesn't leak
    /// across sheet presentations.
    /// Outputs: nothing.
    func resetLogState() { logState = .idle }

    /// User-facing rename error text, special-casing the 409 name collision.
    /// Outputs: the friendly message for the current `renameState`, or "" when
    ///   the rename hasn't failed.
    var renameErrorMessage: String {
        guard case .failed(let error) = renameState else { return "" }
        if error == .server(status: 409) { return "A food with that name already exists." }
        return error.userMessage
    }

    /// User-facing delete error text, special-casing the 409 referenced-food case.
    /// Outputs: the friendly message for the current `deleteState`, or "" when
    ///   the delete hasn't failed.
    var deleteErrorMessage: String {
        guard case .failed(let error) = deleteState else { return "" }
        if error == .server(status: 409) { return "This food is used by past entries or meals and can't be deleted." }
        return error.userMessage
    }

    /// Builds a human-readable quantity label for the logged entry from the
    /// chosen quantity, resolving weighed net grams against the picked container.
    /// Inputs:
    ///   - item: the quantity-sheet result.
    /// Outputs: a label like "150 g", "2 servings", or "1 unit".
    private func quantityText(for item: BatchFoodItem) -> String {
        switch item.quantity {
        case .typed(let value, let unit):
            let n = NumericInput.formatBare(value)
            switch unit {
            case .grams: return "\(n) g"
            case .servings: return "\(n) \(abs(value - 1) < 1e-9 ? "serving" : "servings")"
            case .units: return "\(n) \(abs(value - 1) < 1e-9 ? "unit" : "units")"
            }
        case .weighed(let grossG):
            let tare = containers.first { $0.id == item.containerId }?.tareWeightG ?? 0
            let net = max(0, grossG - tare)
            return "\(Int(net.rounded())) g"
        }
    }
}
