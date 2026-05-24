/// Meal-prep portioning screen.
///
/// Hosts `PrepView`, which lets the user pick a container, enter the total
/// weight reading from the scale, and divide the net food (gross minus tare)
/// into a configurable number of portions. Also drives the container picker
/// sheet, the container-manager sheet, and persists "last used container" in
/// `UserDefaults` for quick re-selection.
import SwiftUI

/// Top-level screen for portioning a batch of prepped food by container + scale weight.
struct PrepView: View {
    @Environment(AuthSession.self) private var auth
    @State private var model = PrepModel()
    @State private var listModel: ContainersListModel?
    @State private var showPicker = false
    @State private var showManager = false

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    section(header: "Container") {
                        Button { showPicker = true } label: {
                            HStack {
                                if let c = model.selectedContainer {
                                    Text(c.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Theme.FG.primary)
                                    Spacer()
                                    Text("\(Int(c.tareWeightG.rounded())) g")
                                        .font(.system(size: 13, design: .monospaced))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.FG.secondary)
                                } else {
                                    Text("Pick a container")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Theme.CTP.mauve)
                                    Spacer()
                                }
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.FG.tertiary)
                                    .padding(.leading, 6)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    section(header: "Total weight on scale") {
                        HStack {
                            TextField(
                                "",
                                value: $model.totalGrams,
                                format: .number,
                                prompt: Text("0").foregroundStyle(Theme.FG.tertiary)
                            )
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(Theme.FG.primary)
                            .tint(Theme.CTP.mauve)
                            .keyboardType(.decimalPad)
                            Text("g")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.FG.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }

                    section(header: "Portions") {
                        // Legacy bridge: Stepper writes portionsOverride; portions reads it back.
                        // TODO(Task 2): replace with multi-container portions UI.
                        let portionsBinding = Binding<Int>(
                            get: { model.portions },
                            set: { model.portionsOverride = $0 }
                        )
                        Stepper(value: portionsBinding, in: 1...50) {
                            Text("\(model.portions)")
                                .font(.system(size: 14, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.FG.primary)
                        }
                        .tint(Theme.CTP.mauve)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }

                    section(header: "Result") {
                        resultRow("Net food", value: model.netGrams)
                        Rectangle().fill(Theme.separator).frame(height: 0.5)
                        resultRow("Per portion", value: model.perPortionGrams)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, Theme.Layout.dockClearance)
            }
        }
        .navigationTitle("Prep")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.BG.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showManager = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            ContainerPickerSheet { picked in applyPick(picked) }
                .environment(auth)
        }
        .sheet(isPresented: $showManager) {
            ContainersListView()
                .environment(auth)
                .onDisappear {
                    Task {
                        await listModel?.load()
                        reconcileSelection()
                    }
                }
        }
        .task {
            if listModel == nil { listModel = ContainersListModel(auth: auth) }
            await listModel?.load()
            applyLastUsedIfNeeded()
            reconcileSelection()
        }
    }

    /// Stores the picked container on the model and remembers it as "last used".
    ///
    /// Inputs:
    /// - c: the container the user picked.
    private func applyPick(_ c: Container) {
        model.selectedContainer = c
        UserDefaults.standard.set(c.id.uuidString, forKey: "prep.lastContainerId")
    }

    /// Restores the previously-used container from `UserDefaults` when nothing
    /// is selected yet and the list has loaded.
    private func applyLastUsedIfNeeded() {
        guard model.selectedContainer == nil,
              let raw = UserDefaults.standard.string(forKey: "prep.lastContainerId"),
              let id = UUID(uuidString: raw),
              case .loaded(let list) = listModel?.state ?? .idle,
              let match = list.first(where: { $0.id == id })
        else { return }
        applyPick(match)
    }

    /// Re-fetch the selected container from the most recently loaded list so
    /// edits propagate (e.g. tare changed in the manager) and deletions clear
    /// the selection. Without this, `selectedContainer` keeps pointing at a
    /// stale snapshot and the math would silently use an outdated tare.
    ///
    /// Replaces the model's `selectedContainer` with the fresh copy when the
    /// stored container still exists, or clears it (and the saved default)
    /// when the container has been deleted.
    private func reconcileSelection() {
        guard let current = model.selectedContainer else { return }
        guard case .loaded(let list) = listModel?.state ?? .idle else { return }
        if let fresh = list.first(where: { $0.id == current.id }) {
            if fresh != current { model.selectedContainer = fresh }
        } else {
            model.selectedContainer = nil
            UserDefaults.standard.removeObject(forKey: "prep.lastContainerId")
        }
    }

    /// Wraps a card-styled content block under an uppercase section header.
    ///
    /// Inputs:
    /// - header: section title shown above the card.
    /// - content: view builder for the card body.
    ///
    /// Outputs: a `View` containing the header label and themed card body.
    @ViewBuilder
    private func section<Content: View>(
        header: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Theme.FG.secondary)
                .padding(.horizontal, 20)
            VStack(spacing: 0) { content() }
                .ctpCard()
                .padding(.horizontal, 16)
        }
    }

    /// Renders a label/value row used in the Result card.
    ///
    /// Inputs:
    /// - label: left-aligned descriptive label.
    /// - value: optional gram value; renders an em-dash placeholder when nil.
    ///
    /// Outputs: a styled row `View` for the result card.
    private func resultRow(_ label: String, value: Double?) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.FG.primary)
            Spacer()
            if let v = value {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(v.rounded()))")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.CTP.mauve)
                    Text("g")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.FG.tertiary)
                }
            } else {
                Text("—")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.FG.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
