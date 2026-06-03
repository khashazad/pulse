/// Settings sheet.
/// Account info + sign-out, theme palette display, weight-goal entry (saved to the
/// server's `MacroTargets.targetWeightLb`), and the display-unit toggle stored in
/// `@AppStorage`. Reuses the shared `SectionCard` and the private `row` helper for layout.
import SwiftUI

/// User-facing settings sheet shown over any tab via the gear toolbar button.
struct SettingsView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(UserTargetsStore.self) private var targetsStore
    @Environment(\.dismiss) private var dismiss

    @State private var targetWeightInput: String = ""
    @State private var targetUnit: WeightUnit = .lb
    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    /// Whether `targetWeightInput` parses to a positive value under 2000.
    /// Outputs: `true` when the input is a valid weight in the chosen unit.
    private var isTargetValid: Bool {
        guard let v = Double(targetWeightInput.replacingOccurrences(of: ",", with: ".")) else { return false }
        return v > 0 && v < 2000
    }

    /// Persists the target weight by converting the user's input to lb and delegating
    /// the fetch/update/upsert sequence to `UserTargetsStore`. No-ops when the input
    /// is unparseable or no client is available.
    private func saveTarget() async {
        guard let v = Double(targetWeightInput.replacingOccurrences(of: ",", with: ".")) else { return }
        let lb = WeightFormatter.toLb(v, from: targetUnit)
        guard let client = auth.makeClient() else { return }
        await targetsStore.saveTargetWeight(lb: lb, client: client)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.secondary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
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

                        SectionCard(header: "Theme", headerHorizontalPadding: 16) {
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

                        SectionCard(header: "Weight goal", headerHorizontalPadding: 16) {
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
                            Rectangle().fill(Theme.separator).frame(height: 0.5)
                            HStack {
                                Spacer()
                                Button("Save target") { Task { await saveTarget() } }
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(isTargetValid ? Theme.CTP.mauve : Theme.FG.tertiary)
                                    .disabled(!isTargetValid)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                            }
                        }

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
                    .padding(.vertical, 16)
                }
            }
            .task {
                guard let client = auth.makeClient() else { return }
                if let current = try? await client.fetchTargets() {
                    targetsStore.update(current)
                    if let lb = current.targetWeightLb {
                        targetWeightInput = String(format: "%.1f", WeightFormatter.fromLb(lb, to: targetUnit))
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.secondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
        }
        .preferredColorScheme(.dark)
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
