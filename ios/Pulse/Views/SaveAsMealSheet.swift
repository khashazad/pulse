// Pulse/Views/SaveAsMealSheet.swift
/// Sheet for saving a selection of logged entries as a new meal. Wraps
/// `MealNameStep` in a `NavigationStack` with a Cancel action. On success it
/// invokes `onCreated` with the new meal, then dismisses. Presented from
/// `DayMacroView`'s multi-select mode.
import SwiftUI

/// The Intake-side "save as meal" sheet.
struct SaveAsMealSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: SaveAsMealSheetModel
    /// Called once the meal is created, with the new meal.
    let onCreated: (Meal) -> Void

    /// Builds the sheet for a set of meal items.
    /// Inputs:
    ///   - items: the items to save (built from the selected entries).
    ///   - auth: auth session used to build the create client.
    ///   - onCreated: completion invoked with the created meal.
    /// Outputs: a configured sheet view.
    init(items: [NewMealItem], auth: AuthSession?, onCreated: @escaping (Meal) -> Void) {
        _model = State(initialValue: SaveAsMealSheetModel(items: items, auth: auth))
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.primary.ignoresSafeArea()
                MealNameStep(model: model)
            }
            .navigationTitle("Save as meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.primary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.FG.secondary)
                }
            }
            .onChange(of: model.created) { _, created in
                guard let created else { return }
                onCreated(created)
                dismiss()
            }
        }
    }
}
