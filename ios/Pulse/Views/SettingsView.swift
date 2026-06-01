/// Settings sheet.
/// Account info + sign-out, theme palette display, the display-unit toggle stored in
/// `@AppStorage`, and macro-target + weight-goal entry. The macro and weight fields are
/// committed together by a single "Save targets" button that PUTs one `MacroTargets`.
/// Reuses the private `section` and `row` helpers for layout.
import SwiftUI

/// User-facing settings sheet shown over any tab via the gear toolbar button.
struct SettingsView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(UserTargetsStore.self) private var targetsStore
    @Environment(\.dismiss) private var dismiss

    @State private var caloriesInput: String = ""
    @State private var proteinInput: String = ""
    @State private var carbsInput: String = ""
    @State private var fatInput: String = ""
    @State private var targetWeightInput: String = ""
    @State private var targetUnit: WeightUnit = .lb
    @State private var isSaving = false
    @State private var saveFailed = false
    /// Last targets loaded from the server, used to detect unsaved edits and to preserve
    /// the goal weight when the user doesn't touch that field. `nil` until a load
    /// succeeds (or when the user has no profile yet).
    @State private var loadedTargets: MacroTargets?
    /// Set when the initial load genuinely failed (network/server) — distinct from a
    /// `404` "no targets yet", which is a normal first-run state.
    @State private var loadFailed = false
    @State private var showDiscardConfirm = false
    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    /// Trims surrounding whitespace from a field value.
    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    /// Parses a macro-gram input, tolerating a comma decimal separator.
    /// Outputs: the parsed value, or `nil` when the text isn't a number.
    private func parseMacro(_ text: String) -> Double? {
        Double(trimmed(text).replacingOccurrences(of: ",", with: "."))
    }

    /// Formats a stored macro-gram value for an input field losslessly, dropping a
    /// trailing ".0" so whole-number targets read as "180" rather than "180.0". Uses
    /// `%.0f` (not `Int(_:)`) for whole values so out-of-range magnitudes can't trap,
    /// and the shortest round-trippable form for fractional values so re-saving an
    /// untouched field doesn't drift its precision.
    private func macroString(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(value)
    }

    /// Converts the weight input to pounds, or `nil` when the field is left blank —
    /// target weight is optional. Unparseable text also returns `nil`; overall validity
    /// is gated separately by `isWeightValidOrEmpty`.
    private func parseWeightLb() -> Double? {
        let text = trimmed(targetWeightInput)
        guard !text.isEmpty,
              let v = Double(text.replacingOccurrences(of: ",", with: "."))
        else { return nil }
        return WeightFormatter.toLb(v, from: targetUnit)
    }

    /// The loaded goal weight rendered in the currently selected unit, or "" when there
    /// is no goal. Mirrors how `load()` populates `targetWeightInput`, so comparing the
    /// two detects whether the user edited the weight field.
    private var loadedWeightString: String {
        guard let lb = loadedTargets?.targetWeightLb else { return "" }
        return String(format: "%.1f", WeightFormatter.fromLb(lb, to: targetUnit))
    }

    /// Whether the user changed the weight field (including clearing it) versus the
    /// value loaded from the server. When `false`, the save preserves the server's
    /// current goal weight instead of overwriting it.
    private var weightFieldDirty: Bool {
        trimmed(targetWeightInput) != loadedWeightString
    }

    /// Whether any field differs from what was last loaded — gates the discard prompt.
    private var hasUnsavedChanges: Bool {
        guard let t = loadedTargets else {
            return !trimmed(caloriesInput).isEmpty
                || !trimmed(proteinInput).isEmpty
                || !trimmed(carbsInput).isEmpty
                || !trimmed(fatInput).isEmpty
                || !trimmed(targetWeightInput).isEmpty
        }
        return trimmed(caloriesInput) != macroString(Double(t.calories))
            || trimmed(proteinInput) != macroString(t.proteinG)
            || trimmed(carbsInput) != macroString(t.carbsG)
            || trimmed(fatInput) != macroString(t.fatG)
            || weightFieldDirty
    }

    /// Whether the four macro inputs parse to a valid target set: positive calories
    /// and non-negative protein/carbs/fat within sane bounds.
    private var areMacrosValid: Bool {
        guard let cals = Int(trimmed(caloriesInput)),
              cals > 0, cals <= 100_000,
              let protein = parseMacro(proteinInput),
              let carbs = parseMacro(carbsInput),
              let fat = parseMacro(fatInput)
        else { return false }
        return [protein, carbs, fat].allSatisfy { $0 >= 0 && $0 <= 10_000 }
    }

    /// Whether the optional target-weight field is either blank or a positive value
    /// under 2000 (in the selected unit).
    private var isWeightValidOrEmpty: Bool {
        let text = trimmed(targetWeightInput)
        if text.isEmpty { return true }
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")) else { return false }
        return v > 0 && v < 2000
    }

    /// Whether the combined macro + weight inputs can be committed right now.
    private var canSave: Bool {
        areMacrosValid && isWeightValidOrEmpty && !isSaving
    }

    /// Loads the current target profile and populates the form. A `404` means the user
    /// has no profile yet (a normal first run) — fields stay blank with no error. Any
    /// other failure sets `loadFailed` so the UI can offer a retry instead of silently
    /// showing an empty form.
    private func load() async {
        guard let client = auth.makeClient() else { return }
        do {
            let current = try await client.fetchTargets()
            loadedTargets = current
            loadFailed = false
            targetsStore.update(current)
            caloriesInput = macroString(Double(current.calories))
            proteinInput = macroString(current.proteinG)
            carbsInput = macroString(current.carbsG)
            fatInput = macroString(current.fatG)
            if let lb = current.targetWeightLb {
                targetWeightInput = String(format: "%.1f", WeightFormatter.fromLb(lb, to: targetUnit))
            } else {
                targetWeightInput = ""
            }
        } catch PulseError.notFound {
            loadedTargets = nil
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    /// Commits every editable target — calories, protein, carbs, fat, and the optional
    /// goal weight — in a single `PUT /targets`. When the user didn't touch the weight
    /// field, the server's current goal weight is re-read and preserved so a value set
    /// elsewhere (another device, the MCP tools) isn't silently clobbered. Updates the
    /// in-memory `targetsStore` and dismisses on success; surfaces `saveFailed` to retry.
    private func saveAll() async {
        guard let cals = Int(trimmed(caloriesInput)),
              let protein = parseMacro(proteinInput),
              let carbs = parseMacro(carbsInput),
              let fat = parseMacro(fatInput),
              let client = auth.makeClient()
        else { return }
        isSaving = true
        saveFailed = false
        do {
            let weightLb: Double?
            if weightFieldDirty {
                weightLb = parseWeightLb()
            } else {
                // Preserve the goal weight the user didn't edit, re-reading the server so
                // an out-of-band change isn't overwritten. Fall back to the load-time
                // value if the re-read fails (e.g. transient error or no profile yet).
                let server = try? await client.fetchTargets()
                weightLb = server?.targetWeightLb ?? loadedTargets?.targetWeightLb
            }
            let updated = MacroTargets(
                calories: cals,
                proteinG: protein,
                carbsG: carbs,
                fatG: fat,
                targetWeightLb: weightLb
            )
            _ = try await client.upsertTargets(updated)
            targetsStore.update(updated)
            loadedTargets = updated
            isSaving = false
            dismiss()
        } catch {
            isSaving = false
            saveFailed = true
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.secondary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        section(header: "Account") {
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

                        section(header: "Theme") {
                            row(label: "Palette") {
                                HStack(spacing: 8) {
                                    HStack(spacing: 3) {
                                        ForEach([Theme.CTP.blue, Theme.CTP.mauve, Theme.CTP.pink, Theme.CTP.peach, Theme.CTP.green], id: \.self.description) { color in
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

                        section(header: "Display unit") {
                            row(label: "Weight unit") {
                                Picker("Display unit", selection: $displayUnitRaw) {
                                    Text("lb").tag(WeightUnit.lb.rawValue)
                                    Text("kg").tag(WeightUnit.kg.rawValue)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 110)
                            }
                        }

                        if loadFailed {
                            HStack(spacing: 8) {
                                Text("Couldn't load your current targets.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.CTP.red)
                                Spacer()
                                Button("Retry") { Task { await load() } }
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.CTP.mauve)
                            }
                            .padding(.horizontal, 20)
                        }

                        section(header: "Macro targets") {
                            row(label: "Calories") {
                                macroField($caloriesInput, placeholder: "e.g. 2200", decimal: false, unit: "kcal")
                            }
                            Rectangle().fill(Theme.separator).frame(height: 0.5)
                            row(label: "Protein") {
                                macroField($proteinInput, placeholder: "e.g. 180", decimal: true, unit: "g")
                            }
                            Rectangle().fill(Theme.separator).frame(height: 0.5)
                            row(label: "Carbs") {
                                macroField($carbsInput, placeholder: "e.g. 200", decimal: true, unit: "g")
                            }
                            Rectangle().fill(Theme.separator).frame(height: 0.5)
                            row(label: "Fat") {
                                macroField($fatInput, placeholder: "e.g. 70", decimal: true, unit: "g")
                            }
                        }

                        section(header: "Weight goal", footer: "Leave blank to clear your goal weight.") {
                            row(label: "Target weight") {
                                HStack(spacing: 8) {
                                    TextField("e.g. 170", text: $targetWeightInput)
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 80)
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Theme.FG.primary)
                                    Picker("Unit", selection: $targetUnit) {
                                        Text("lb").tag(WeightUnit.lb)
                                        Text("kg").tag(WeightUnit.kg)
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 90)
                                    .onChange(of: targetUnit) { oldUnit, newUnit in
                                        guard oldUnit != newUnit,
                                              let v = Double(targetWeightInput.replacingOccurrences(of: ",", with: "."))
                                        else { return }
                                        let lb = WeightFormatter.toLb(v, from: oldUnit)
                                        targetWeightInput = String(format: "%.1f", WeightFormatter.fromLb(lb, to: newUnit))
                                    }
                                }
                            }
                        }

                        VStack(spacing: 8) {
                            Button {
                                Task { await saveAll() }
                            } label: {
                                Text(isSaving ? "Saving…" : "Save targets")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(canSave ? Theme.CTP.mauve : Theme.CTP.mauve.opacity(0.4))
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .disabled(!canSave)

                            if saveFailed {
                                Text("Couldn't save. Check your connection and try again.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.CTP.red)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 16)
                }
            }
            .task { await load() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.secondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if hasUnsavedChanges {
                            showDiscardConfirm = true
                        } else {
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.CTP.mauve)
                }
            }
            .confirmationDialog(
                "Discard unsaved changes?",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) { }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Layout helper that wraps `content` in a card with optional uppercase header
    /// caption and a tertiary footer caption.
    /// Inputs:
    ///   - header: optional uppercase caption rendered above the card.
    ///   - footer: optional caption rendered below the card.
    ///   - content: rows to embed inside the card.
    /// Outputs: composed section view.
    @ViewBuilder
    private func section<Content: View>(
        header: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.FG.secondary)
                    .padding(.horizontal, 16)
            }
            VStack(spacing: 0) { content() }
                .ctpCard()
                .padding(.horizontal, 16)
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.FG.tertiary)
                    .padding(.horizontal, 20)
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

    /// Trailing numeric input used by the macro-target rows: a right-aligned monospaced
    /// text field followed by a fixed unit caption.
    /// Inputs:
    ///   - text: binding to the field's string contents.
    ///   - placeholder: hint shown when the field is empty.
    ///   - decimal: `true` for gram fields (`.decimalPad`), `false` for calories (`.numberPad`).
    ///   - unit: unit caption rendered after the field (e.g. "g", "kcal").
    /// Outputs: composed trailing control for use inside a `row`.
    private func macroField(
        _ text: Binding<String>,
        placeholder: String,
        decimal: Bool,
        unit: String
    ) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .keyboardType(decimal ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.FG.primary)
            Text(unit)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.FG.tertiary)
                .frame(width: 34, alignment: .leading)
        }
    }
}

#Preview {
    SettingsView()
        .environment(AuthSession(baseURL: URL(string: "https://example.test")!))
        .environment(UserTargetsStore())
}
