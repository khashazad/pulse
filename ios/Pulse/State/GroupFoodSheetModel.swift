// Pulse/State/GroupFoodSheetModel.swift
/// View-model for the grouping sheet. Holds the editable Food name, a per-portion
/// label draft, the chosen default portion, and the create action's state. Labels
/// are pre-filled via PortionLabel.derive and re-derived when the name changes
/// until the user manually edits a given label. `save()` calls `createFood`.
import Foundation
import Observation

/// One editable portion line in the grouping sheet.
struct PortionDraft: Identifiable, Equatable {
    let food: CustomFood
    var label: String
    var id: UUID { food.id }
}

@Observable
final class GroupFoodSheetModel {
    var name: String { didSet { rederiveUneditedLabels() } }
    var portions: [PortionDraft]
    var defaultPortionId: UUID
    var errorMessage: String?
    var isSaving = false
    /// Set to the created Food on success so the view can dismiss + propagate.
    var created: Food?
    private var editedLabels: Set<UUID> = []
    private weak var auth: AuthSession?

    /// Builds the form for a set of foods being grouped (precondition: non-empty).
    /// Inputs:
    ///   - foods: the selected standalone custom foods to group.
    ///   - auth: auth session used to build an authenticated client on save.
    /// Outputs: a configured model with pre-filled labels and a default portion.
    init(foods: [CustomFood], auth: AuthSession?) {
        let suggested = FoodDuplicateGrouper.suggestedName(for: foods)
        self.name = suggested
        self.portions = foods.map {
            PortionDraft(food: $0, label: PortionLabel.derive(foodName: suggested, portionName: $0.name))
        }
        self.defaultPortionId = foods.first?.id ?? UUID()
        self.auth = auth
    }

    /// Records a user label edit (so name changes stop re-deriving this label).
    /// Inputs:
    ///   - label: the new label text.
    ///   - id: the portion's custom-food id.
    /// Outputs: nothing; mutates `portions` and marks the label edited.
    func setLabel(_ label: String, for id: UUID) {
        editedLabels.insert(id)
        if let i = portions.firstIndex(where: { $0.id == id }) { portions[i].label = label }
    }

    /// Re-derives labels the user hasn't manually edited from the current name.
    /// Outputs: nothing; mutates `portions`.
    private func rederiveUneditedLabels() {
        for i in portions.indices where !editedLabels.contains(portions[i].id) {
            portions[i].label = PortionLabel.derive(foodName: name, portionName: portions[i].food.name)
        }
    }

    /// Creates the Food via `createFood`. On success sets `created`; on failure
    /// sets `errorMessage` (409 → name-clash message). No-op while already saving.
    /// Outputs: nothing; drives `isSaving`/`created`/`errorMessage`.
    func save() async {
        guard !isSaving else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { errorMessage = "Name can't be empty."; return }
        guard let client = auth?.makeClient() else { errorMessage = "Not signed in."; return }
        isSaving = true; errorMessage = nil
        let labels = Dictionary(uniqueKeysWithValues: portions.map { ($0.id, $0.label) })
        do {
            created = try await client.createFood(
                name: trimmed, portionIds: portions.map(\.id),
                defaultPortionId: defaultPortionId, portionLabels: labels, aliases: [])
        } catch let error as PulseError {
            errorMessage = error == .server(status: 409)
                ? "A food with that name already exists." : error.userMessage
        } catch {
            errorMessage = "Couldn't create the food."
        }
        isSaving = false
    }

    /// The ids of all portions, in display order (for the create call / wiring).
    /// Outputs: the portions' custom-food ids in their display order.
    var portionIds: [UUID] { portions.map(\.id) }
}
