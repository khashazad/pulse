/// Settings sheet.
/// Account info + sign-out, theme palette display, editable macro targets and
/// weight goal (accumulated in a `TargetsDraft` and saved together via the
/// top-right Save action), and the instant display-unit toggle stored in
/// `@AppStorage`. Close (top-left) confirms before discarding pending edits.
import SwiftUI

/// User-facing settings sheet shown over any tab via the gear toolbar button.
struct SettingsView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(UserTargetsStore.self) private var targetsStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = TargetsDraft()
    @State private var isSaving = false
    @State private var saveFailed = false
    @State private var showDiscardDialog = false
    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.secondary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        if saveFailed { errorBanner }
                        accountSection
                        signOutButton
                        themeSection
                        macroTargetsSection
                        weightGoalSection
                        displayUnitSection
                    }
                    .padding(.vertical, 16)
                }
            }
            .task { await loadTargets() }
            .onChange(of: draft) { _, _ in saveFailed = false }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.secondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if draft.isDirty {
                            showDiscardDialog = true
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.CTP.mauve)
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .tint(Theme.CTP.mauve)
                    } else if draft.isDirty {
                        Button("Save") { Task { await save() } }
                            .fontWeight(.semibold)
                            .foregroundStyle(draft.isValid ? Theme.CTP.mauve : Theme.FG.tertiary)
                            .disabled(!draft.isValid)
                    }
                }
            }
            .confirmationDialog(
                "Discard changes?",
                isPresented: $showDiscardDialog,
                titleVisibility: .visible
            ) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your edits to targets haven't been saved.")
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(draft.isDirty)
    }

    // MARK: - data flow

    /// Fetches current targets, updates the shared cache, and seeds the draft.
    /// A 404 (no profile yet) or fetch failure seeds an empty draft — the
    /// first Save then creates the profile. Outputs: nothing.
    private func loadTargets() async {
        guard let client = auth.makeClient() else { return }
        let current = try? await client.fetchTargets()
        if let current { targetsStore.update(current) }
        draft.seed(from: current, unit: .lb)
    }

    /// Saves all pending target edits with one PUT /targets. On success the
    /// draft re-seeds (clearing dirty, hiding Save); on failure the sheet
    /// stays open with the error banner shown. Outputs: nothing.
    private func save() async {
        guard let targets = draft.toMacroTargets(),
              let client = auth.makeClient() else { return }
        isSaving = true
        saveFailed = false
        do {
            let persisted = try await targetsStore.save(targets, client: client)
            draft.seed(from: persisted, unit: draft.weightUnit)
        } catch {
            saveFailed = true
        }
        isSaving = false
    }

    // MARK: - sections

    /// Inline error banner shown above the cards after a failed save.
    private var errorBanner: some View {
        Text("Couldn't save — check your connection and try again.")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.CTP.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.CTP.red.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
    }

    /// Account card: email + configured server URL.
    private var accountSection: some View {
        SectionCard(header: "Account", headerHorizontalPadding: 16) {
            row(label: "Email") {
                Text(auth.email ?? "—")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.CTP.mauve)
            }
            Rectangle().fill(Theme.separator).frame(height: 0.5)
            row(label: "Server") {
                Text(Constants.baseURL.absoluteString)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.FG.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// Sign-out button; ends the session and closes the sheet.
    private var signOutButton: some View {
        Button {
            Task { @MainActor in
                await auth.signOut()
                dismiss()
            }
        } label: {
            Text("Sign Out")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.CTP.peach)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.horizontal, 16)
    }

    /// Theme card: palette swatches + appearance label (display-only).
    private var themeSection: some View {
        SectionCard(header: "Theme", headerHorizontalPadding: 16) {
            row(label: "Palette") {
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        ForEach(
                            [Theme.CTP.blue, Theme.CTP.mauve, Theme.CTP.pink, Theme.CTP.peach, Theme.CTP.green],
                            id: \.self.description
                        ) { color in
                            Circle().fill(color).frame(width: 10, height: 10)
                        }
                    }
                    Text("Macchiato")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.FG.primary)
                }
            }
            Rectangle().fill(Theme.separator).frame(height: 0.5)
            row(label: "Appearance") {
                Text("Always dark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.FG.secondary)
            }
        }
    }

    /// Macro targets card: four editable fields plus the computed-kcal
    /// indicator row while the section has unsaved edits.
    private var macroTargetsSection: some View {
        SectionCard(header: "Macro targets", headerHorizontalPadding: 16) {
            macroRow(label: "Calories", text: $draft.caloriesInput, unit: "kcal",
                     edited: draft.isCaloriesEdited, keyboard: .numberPad)
            Rectangle().fill(Theme.separator).frame(height: 0.5)
            macroRow(label: "Protein", text: $draft.proteinInput, unit: "g",
                     edited: draft.isProteinEdited, keyboard: .decimalPad)
            Rectangle().fill(Theme.separator).frame(height: 0.5)
            macroRow(label: "Carbs", text: $draft.carbsInput, unit: "g",
                     edited: draft.isCarbsEdited, keyboard: .decimalPad)
            Rectangle().fill(Theme.separator).frame(height: 0.5)
            macroRow(label: "Fat", text: $draft.fatInput, unit: "g",
                     edited: draft.isFatEdited, keyboard: .decimalPad)
            if draft.isMacroDirty {
                Rectangle().fill(Theme.separator).frame(height: 0.5)
                HStack(spacing: 8) {
                    Circle().fill(Theme.CTP.peach).frame(width: 6, height: 6)
                    Text("≈ \(draft.computedCalories) kcal from macros")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.CTP.peach)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    /// Weight goal card: target weight field + entry-unit picker. Saved via
    /// the unified Save action (no inline save button).
    private var weightGoalSection: some View {
        SectionCard(header: "Weight goal", headerHorizontalPadding: 16) {
            row(label: "Target weight") {
                HStack(spacing: 8) {
                    TextField("e.g. 170", text: $draft.weightInput)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(draft.isWeightEdited ? Theme.CTP.pink : Theme.FG.primary)
                    Picker("Unit", selection: Binding(
                        get: { draft.weightUnit },
                        set: { draft.setUnit($0) }
                    )) {
                        Text("lb").tag(WeightUnit.lb)
                        Text("kg").tag(WeightUnit.kg)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 90)
                }
            }
        }
    }

    /// Display-unit card: instant local preference, outside the Save flow.
    private var displayUnitSection: some View {
        SectionCard(header: "Display unit", headerHorizontalPadding: 16) {
            row(label: "Weight unit") {
                Picker("Display unit", selection: $displayUnitRaw) {
                    Text("lb").tag(WeightUnit.lb.rawValue)
                    Text("kg").tag(WeightUnit.kg.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }
        }
    }

    // MARK: - row helpers

    /// Editable numeric row used inside the macro targets card.
    /// Inputs:
    ///   - label: field name on the leading edge.
    ///   - text: binding to the raw draft input string.
    ///   - unit: trailing unit suffix ("kcal" / "g").
    ///   - edited: whether the field differs from baseline (tints the value).
    ///   - keyboard: keyboard type for the field.
    /// Outputs: composed row view.
    private func macroRow(
        label: String,
        text: Binding<String>,
        unit: String,
        edited: Bool,
        keyboard: UIKeyboardType
    ) -> some View {
        row(label: label) {
            HStack(spacing: 6) {
                TextField("0", text: text)
                    .keyboardType(keyboard)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(edited ? Theme.CTP.pink : Theme.FG.primary)
                Text(unit)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.FG.tertiary)
                    .frame(width: 28, alignment: .leading)
            }
        }
    }

    /// Standard label/trailing-control row used inside settings cards.
    /// Inputs:
    ///   - label: primary text on the leading edge.
    ///   - trailing: control or value rendered on the trailing edge.
    /// Outputs: composed row view.
    private func row<Trailing: View>(
        label: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.FG.primary)
                .frame(minWidth: 70, alignment: .leading)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#Preview {
    SettingsView()
        .environment(AuthSession(baseURL: URL(string: "https://example.test")!))
        .environment(UserTargetsStore())
}
