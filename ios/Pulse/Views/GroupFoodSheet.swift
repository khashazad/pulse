// Pulse/Views/GroupFoodSheet.swift
/// Sheet for grouping a set of standalone custom foods into one Food. Lets the
/// user name the Food, edit each portion's label, pick the default portion, and
/// create it via `GroupFoodSheetModel.save()`. On success it invokes `onCreated`
/// with the new Food and the set of grouped portion ids, then dismisses. Not yet
/// wired into the Food tab — presented standalone for now.
import SwiftUI

/// The grouping sheet: name field + per-portion label/default rows + create.
struct GroupFoodSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Form state (name, portion drafts, default selection, create action).
    @State private var model: GroupFoodSheetModel
    /// Called once the Food is created, with the Food and its grouped portion ids.
    let onCreated: (Food, Set<UUID>) -> Void

    /// Builds the sheet for a selection of custom foods.
    /// Inputs:
    ///   - foods: the standalone custom foods to group (non-empty).
    ///   - auth: auth session used to build the create client.
    ///   - onCreated: completion invoked with the created Food + grouped ids.
    /// Outputs: a configured sheet view.
    init(foods: [CustomFood], auth: AuthSession?, onCreated: @escaping (Food, Set<UUID>) -> Void) {
        _model = State(initialValue: GroupFoodSheetModel(foods: foods, auth: auth))
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.primary.ignoresSafeArea()
                content
            }
            .navigationTitle("Group into food")
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
                onCreated(created, Set(model.portionIds))
                dismiss()
            }
        }
    }

    /// The scrollable form body: name card, portion list, error line, create button.
    /// Outputs: the composed content view.
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                nameCard
                portionsSection
                errorRow
                createButton
                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.top, 8)
        }
    }

    /// The Food-name input, in a labelled section card.
    /// Outputs: the name-entry card.
    private var nameCard: some View {
        SectionCard(header: "Food name", headerHorizontalPadding: 20) {
            TextField("Name", text: $model.name)
                .font(.system(size: 16))
                .foregroundStyle(Theme.FG.primary)
                .tint(Theme.CTP.mauve)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
    }

    /// The list of editable portion rows under a "Portions" header.
    /// Outputs: the portions section card.
    private var portionsSection: some View {
        SectionCard(header: "Portions", footer: "Tap a portion to make it the default.",
                    headerHorizontalPadding: 20) {
            ForEach(Array(model.portions.enumerated()), id: \.element.id) { index, portion in
                if index > 0 {
                    Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 14)
                }
                portionRow(portion)
            }
        }
    }

    /// One portion row: food name caption + default selector + editable label.
    /// Inputs:
    ///   - portion: the portion draft to render.
    /// Outputs: the composed row view.
    private func portionRow(_ portion: PortionDraft) -> some View {
        let isDefault = model.defaultPortionId == portion.id
        return HStack(spacing: 12) {
            Button {
                model.defaultPortionId = portion.id
            } label: {
                Image(systemName: isDefault ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isDefault ? Theme.CTP.mauve : Theme.FG.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDefault ? "Default portion" : "Make default portion")

            VStack(alignment: .leading, spacing: 4) {
                Text(portion.food.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.FG.tertiary)
                TextField("Label", text: labelBinding(for: portion.id))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.FG.primary)
                    .tint(Theme.CTP.mauve)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// A two-way binding for a portion's label that routes edits through
    /// `model.setLabel` (so the model can stop re-deriving an edited label).
    /// Inputs:
    ///   - id: the portion's custom-food id.
    /// Outputs: a `Binding<String>` over the portion's label.
    private func labelBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { model.portions.first(where: { $0.id == id })?.label ?? "" },
            set: { model.setLabel($0, for: id) }
        )
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
            title: "Create food",
            leading: .busy(model.isSaving),
            disabled: model.isSaving || blank
        ) {
            Task { await model.save() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}
