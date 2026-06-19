// Pulse/State/SaveAsMealSheetModel.swift
/// View-model for the "save selection as meal" sheet. Holds the editable meal
/// name, the (immutable) items being saved, and the create action's state.
/// `save()` calls `createMeal`; on success `created` is set so the host can
/// dismiss and react. Used by both the Intake path (`SaveAsMealSheet`) and the
/// Food-tab wizard's final step.
import Foundation
import Observation

/// Observable form state for creating a meal from a selection.
@Observable
final class SaveAsMealSheetModel {
    var name: String
    /// The items being saved (frozen at construction).
    let items: [NewMealItem]
    var errorMessage: String?
    var isSaving = false
    /// Set to the created meal on success so the view can dismiss + propagate.
    var created: Meal?
    private weak var auth: AuthSession?

    /// Builds the form for a set of meal items.
    /// Inputs:
    ///   - items: the items to include in the new meal (non-empty in practice).
    ///   - suggestedName: an initial name to pre-fill (default empty).
    ///   - auth: auth session used to build the create client on save.
    /// Outputs: a configured model.
    init(items: [NewMealItem], suggestedName: String = "", auth: AuthSession?) {
        self.items = items
        self.name = suggestedName
        self.auth = auth
    }

    /// Creates the meal via `createMeal`. On success sets `created`; on failure
    /// sets `errorMessage` (409 → name-clash). No-op while already saving, on a
    /// blank name, or with no items.
    /// Outputs: nothing; drives `isSaving`/`created`/`errorMessage`.
    func save() async {
        guard !isSaving else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { errorMessage = "Name can't be empty."; return }
        guard !items.isEmpty else { errorMessage = "Add at least one item."; return }
        guard let client = auth?.makeClient() else { errorMessage = "Not signed in."; return }
        isSaving = true; errorMessage = nil
        do {
            created = try await client.createMeal(name: trimmed, items: items)
        } catch let error as PulseError {
            errorMessage = error == .server(status: 409)
                ? "A meal with that name already exists." : error.userMessage
        } catch {
            errorMessage = "Couldn't create the meal."
        }
        isSaving = false
    }
}
