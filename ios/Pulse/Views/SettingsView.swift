/// Settings sheet.
/// Account info + sign-out, theme palette display, editable macro targets and
/// weight goal (accumulated in a `TargetsDraft` and saved together via the
/// top-right Save action), and the instant display-unit toggle stored in
/// `@AppStorage`. Close (top-left) confirms before discarding pending edits.
/// When loading targets fails (other than 404/no-profile) the editable cards
/// are replaced by a retry affordance so a blank form can't overwrite state.
import SwiftUI

/// User-facing settings sheet shown over any tab via the gear toolbar button.
struct SettingsView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(UserTargetsStore.self) private var targetsStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = TargetsDraft()
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var loadFailed = false
    @State private var showDiscardDialog = false
    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    /// The user's persisted weight display preference, used to seed the
    /// weight-goal entry unit so the sheet opens in the unit they expect.
    private var displayUnit: WeightUnit {
        WeightUnit(rawValue: displayUnitRaw) ?? .defaultDisplayUnit
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.secondary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        if let saveError { errorBanner(saveError) }
                        accountSection
                        signOutButton
                        themeSection
                        if loadFailed {
                            loadFailedSection
                        } else {
                            macroTargetsSection
                            weightGoalSection
                        }
                        displayUnitSection
                    }
                    .padding(.vertical, 16)
                }
            }
            .task { await loadTargets() }
            .onChange(of: draft) { old, new in
                // A pure unit toggle (setUnit mutates weightUnit and rewrites
                // the input atomically) is not a user edit — keep the save
                // error visible for it; clear it on real field edits.
                if old.weightUnit == new.weightUnit { saveError = nil }
            }
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

    /// Fetches current targets, updates the shared cache, and seeds the draft
    /// in the user's preferred display unit. A 404 (no profile yet) seeds an
    /// empty draft — the first Save then creates the profile. Any other
    /// failure flips `loadFailed` so the editable cards are replaced by a
    /// retry affordance instead of a blank form that could overwrite server
    /// state. Outputs: nothing.
    private func loadTargets() async {
        guard let client = auth.makeClient() else { return }
        loadFailed = false
        do {
            let current = try await client.fetchTargets()
            targetsStore.update(current)
            draft.seed(from: current, unit: displayUnit)
        } catch PulseError.notFound {
            draft.seed(from: nil, unit: displayUnit)
        } catch {
            loadFailed = true
        }
    }

    /// Saves all pending target edits with one PUT /targets, first re-fetching
    /// the latest server profile so unedited fields can't clobber concurrent
    /// changes made by other clients while the sheet was open. On success the
    /// draft re-seeds from the server echo; on failure the sheet stays open
    /// with an error banner matched to the failure kind. Outputs: nothing.
    private func save() async {
        guard !isSaving, let client = auth.makeClient() else { return }
        isSaving = true
        saveError = nil
        let fresh = try? await client.fetchTargets()
        if let targets = draft.toMacroTargets(merging: fresh) {
            do {
                let persisted = try await targetsStore.save(targets, client: client)
                draft.seed(from: persisted, unit: draft.weightUnit)
            } catch PulseError.unauthorized, PulseError.notSignedIn {
                saveError = "Session expired — sign in again to save."
            } catch {
                saveError = "Couldn't save — check your connection and try again."
            }
        }
        isSaving = false
    }

    // MARK: - sections

    /// Inline error banner shown above the cards after a failed save.
    /// Inputs:
    ///   - message: failure copy matched to the error kind.
    /// Outputs: composed banner view.
    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.CTP.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.CTP.red.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
    }

    /// Replaces the editable target cards when fetching targets failed for a
    /// reason other than "no profile yet": explains the load failure and
    /// offers a retry instead of presenting a blank editable form.
    private var loadFailedSection: some View {
        SectionCard(header: "Targets", headerHorizontalPadding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Couldn't load your current targets.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.CTP.red)
                Button("Retry") { Task { await loadTargets() } }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.CTP.mauve)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
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
                     edited: draft.isCaloriesEdited, valid: draft.isCaloriesFieldValid,
                     keyboard: .numberPad)
            Rectangle().fill(Theme.separator).frame(height: 0.5)
            macroRow(label: "Protein", text: $draft.proteinInput, unit: "g",
                     edited: draft.isProteinEdited, valid: draft.isProteinFieldValid,
                     keyboard: .decimalPad)
            Rectangle().fill(Theme.separator).frame(height: 0.5)
            macroRow(label: "Carbs", text: $draft.carbsInput, unit: "g",
                     edited: draft.isCarbsEdited, valid: draft.isCarbsFieldValid,
                     keyboard: .decimalPad)
            Rectangle().fill(Theme.separator).frame(height: 0.5)
            macroRow(label: "Fat", text: $draft.fatInput, unit: "g",
                     edited: draft.isFatEdited, valid: draft.isFatFieldValid,
                     keyboard: .decimalPad)
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
                        .foregroundStyle(fieldTint(edited: draft.isWeightEdited,
                                                   valid: draft.isWeightFieldValid))
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

    /// Tint for an editable target field: red when invalid (explains the
    /// disabled Save), pink when edited, default otherwise.
    /// Inputs:
    ///   - edited: whether the field differs from baseline.
    ///   - valid: whether the field parses inside its bounds.
    /// Outputs: the field's foreground color.
    private func fieldTint(edited: Bool, valid: Bool) -> Color {
        if !valid { return Theme.CTP.red }
        return edited ? Theme.CTP.pink : Theme.FG.primary
    }

    /// Editable numeric row used inside the macro targets card.
    /// Inputs:
    ///   - label: field name on the leading edge.
    ///   - text: binding to the raw draft input string.
    ///   - unit: trailing unit suffix ("kcal" / "g").
    ///   - edited: whether the field differs from baseline (tints the value).
    ///   - valid: whether the field parses inside its bounds (red when not).
    ///   - keyboard: keyboard type for the field.
    /// Outputs: composed row view.
    private func macroRow(
        label: String,
        text: Binding<String>,
        unit: String,
        edited: Bool,
        valid: Bool,
        keyboard: UIKeyboardType
    ) -> some View {
        row(label: label) {
            HStack(spacing: 6) {
                TextField("0", text: text)
                    .keyboardType(keyboard)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    // An untouched empty field (new profile) isn't flagged red.
                    .foregroundStyle(fieldTint(edited: edited,
                                               valid: valid || text.wrappedValue.isEmpty))
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
