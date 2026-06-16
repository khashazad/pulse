/// Detail screen for one saved custom food. Shows per-basis macros (hero card
/// with a distribution bar + totals row + basis-context line) and three actions:
/// rename (alert), delete (confirmation), and log-to-today (reuses the shared
/// `QuantityEntryView`). Mutations are applied to the parent list via the
/// `onRenamed` / `onDeleted` callbacks so it refreshes without a refetch.
import SwiftUI

/// Custom-food detail + actions screen.
struct CustomFoodDetailView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(\.dismiss) private var dismiss

    let food: CustomFood
    /// Called with the updated food after a successful rename.
    let onRenamed: (CustomFood) -> Void
    /// Called with the food's id after a successful delete.
    let onDeleted: (UUID) -> Void

    @State private var model: CustomFoodDetailModel?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var showDeleteConfirm = false
    @State private var showLogSheet = false

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            if let model {
                content(model: model)
            } else {
                ProgressView().tint(Theme.CTP.mauve)
            }
        }
        .navigationTitle(model?.food.name ?? food.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.BG.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            if model == nil { model = CustomFoodDetailModel(food: food, auth: auth) }
            await model?.loadContainers()
        }
    }

    /// Loaded content: hero macro card + the three action buttons + sheets/alerts.
    /// Inputs:
    ///   - model: the bound detail model.
    /// Outputs: composed scrollable view.
    @ViewBuilder
    private func content(model: CustomFoodDetailModel) -> some View {
        let current = model.food
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heroCard(food: current)
                    .padding(.horizontal, 16)

                actions(model: model)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.top, 6)
        }
        .alert("Rename food", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                Task {
                    await model.rename(to: trimmed)
                    switch model.renameState {
                    case .saved:
                        renameError = nil
                        onRenamed(model.food)
                    case .failed:
                        renameError = model.renameErrorMessage
                    default:
                        break
                    }
                }
            }
        } message: {
            Text("Choose a new name for this food.")
        }
        .confirmationDialog("Delete this food?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.delete()
                    if case .deleted = model.deleteState {
                        onDeleted(model.food.id)
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved custom food. It can't be deleted if past entries or meals still reference it.")
        }
        .sheet(isPresented: $showLogSheet) {
            QuantityEntryView(result: model.asSearchResult, containers: model.containers) { item in
                Task { await model.log(item) }
            }
        }
    }

    /// Hero card: per-basis totals, macro distribution bar, totals row, and the
    /// basis-context line (e.g. "1 serving = 1 scoop").
    /// Inputs:
    ///   - food: the current (possibly renamed) custom food.
    /// Outputs: composed card view.
    private func heroCard(food: CustomFood) -> some View {
        let totals = MacroTotals(calories: food.calories, proteinG: food.proteinG,
                                 carbsG: food.carbsG, fatG: food.fatG)
        let nutrition = FoodNutrition(basis: food.basis, servingSize: food.servingSize,
                                      servingSizeUnit: food.servingSizeUnit, caloriesPerBasis: food.calories,
                                      proteinGPerBasis: food.proteinG, carbsGPerBasis: food.carbsG,
                                      fatGPerBasis: food.fatG)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Per basis")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.FG.secondary)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(food.calories)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.FG.primary)
                    Text("cal")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.FG.tertiary)
                }
            }
            MacroDistributionBar(proteinG: food.proteinG, carbsG: food.carbsG, fatG: food.fatG)
            MacroTotalsRow(totals: totals, targets: nil)
            Text(nutrition.basisContextLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.FG.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .ctpCard()
    }

    /// The three stacked action buttons: Log to today, Rename, Delete.
    /// Inputs:
    ///   - model: the bound detail model (for state + triggering actions).
    /// Outputs: composed actions view.
    private func actions(model: CustomFoodDetailModel) -> some View {
        VStack(spacing: 10) {
            PrimaryActionButton(title: "Log to today", leading: .icon("plus.circle.fill"), disabled: false) {
                model.resetLogState()
                showLogSheet = true
            }
            Button {
                renameText = model.food.name
                renameError = nil
                showRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.CTP.mauve)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .ctpCard()
            }
            .buttonStyle(.plain)
            renameStatusRow
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.CTP.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .ctpCard()
            }
            .buttonStyle(.plain)

            logStatusRow(model: model)
        }
    }

    /// Inline error row for a failed rename (the alert can't show it because it
    /// dismisses before the async rename resolves).
    /// Outputs: a red error label when a rename error is set, else empty.
    @ViewBuilder
    private var renameStatusRow: some View {
        if let renameError {
            Label(renameError, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.CTP.red)
        }
    }

    /// Inline status line for the log action (success confirmation + error text).
    /// Inputs:
    ///   - model: the bound detail model.
    /// Outputs: a status label, or empty when idle/logging.
    @ViewBuilder
    private func logStatusRow(model: CustomFoodDetailModel) -> some View {
        switch model.logState {
        case .logged:
            Label("Logged to today", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.CTP.green)
        case .failed(let error):
            Label(error.userMessage, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.CTP.red)
        case .idle, .logging:
            EmptyView()
        }
    }
}
