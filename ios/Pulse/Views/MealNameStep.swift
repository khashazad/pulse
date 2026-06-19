// Pulse/Views/MealNameStep.swift
/// Reusable inner content for creating a meal: a name field, a read-only preview
/// of the items being saved (name + calories), an inline error line, and the
/// create button. No `NavigationStack` of its own — the host provides chrome.
/// Used by `SaveAsMealSheet` (Intake) and `SaveFoodsAsMealSheet` (Food tab).
import SwiftUI

/// The name + preview + create body, bound to a `SaveAsMealSheetModel`.
struct MealNameStep: View {
    @Bindable var model: SaveAsMealSheetModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                nameCard
                itemsSection
                errorRow
                createButton
                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.top, 8)
        }
    }

    /// The meal-name input in a labelled card.
    /// Outputs: the name-entry card.
    private var nameCard: some View {
        SectionCard(header: "Meal name", headerHorizontalPadding: 20) {
            TextField("Name", text: $model.name)
                .font(.system(size: 16))
                .foregroundStyle(Theme.FG.primary)
                .tint(Theme.CTP.mauve)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
    }

    /// Read-only list of the items being saved, with per-item calories.
    /// Outputs: the items preview card.
    private var itemsSection: some View {
        SectionCard(header: "\(model.items.count) item\(model.items.count == 1 ? "" : "s")",
                    headerHorizontalPadding: 20) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 14)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.FG.primary)
                        Text(item.quantityText)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.FG.tertiary)
                    }
                    Spacer(minLength: 0)
                    Text("\(item.calories) kcal")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.FG.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    /// Inline error line shown when the create action fails or input is invalid.
    /// Outputs: a red error label when `errorMessage` is set, else empty.
    @ViewBuilder
    private var errorRow: some View {
        if let message = model.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.CTP.red)
                .padding(.horizontal, 20)
        }
    }

    /// The create button: disabled while saving or when the name is blank.
    /// Outputs: the primary create action button.
    private var createButton: some View {
        let blank = model.name.trimmingCharacters(in: .whitespaces).isEmpty
        return PrimaryActionButton(
            title: "Create meal",
            leading: .busy(model.isSaving),
            disabled: model.isSaving || blank
        ) {
            Task { await model.save() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}
