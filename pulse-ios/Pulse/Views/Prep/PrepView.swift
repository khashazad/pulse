/// Multi-container meal-prep portioning screen.
///
/// Hosts `PrepView`: the user chooses the target containers to divide a batch
/// into (a list, or one container with a count), records one or more weigh-ins
/// (gross scale readings, each minus its container's tare), and reads back the
/// total net food, an even per-container fill target, and a decoupled per-portion
/// serving size. Reuses `ContainerPickerSheet` for selection, drives the
/// container-manager sheet, and persists in-progress state to `UserDefaults`.
import SwiftUI

/// Persisted shape of a target entry (container id + count) in `UserDefaults`.
private struct PersistedPrepTarget: Codable {
    let containerId: String
    let count: Int
}

/// Persisted shape of a weigh-in (container id + optional gross) in `UserDefaults`.
private struct PersistedPrepWeighIn: Codable {
    let containerId: String
    let grossGrams: Double?
}

/// Top-level screen for portioning one cooked batch across multiple containers.
struct PrepView: View {
    @Environment(AuthSession.self) private var auth
    @State private var model = PrepModel()
    @State private var listModel: ContainersListModel?
    @State private var pickerMode: PickerMode?
    @State private var showManager = false
    @State private var hydrated = false

    /// Identifies which selection the container picker is fulfilling.
    private enum PickerMode: Identifiable {
        case addTarget
        case addWeighIn
        case changeWeighIn(UUID)

        /// Stable id so `.sheet(item:)` can present the picker.
        var id: String {
            switch self {
            case .addTarget: return "addTarget"
            case .addWeighIn: return "addWeighIn"
            case .changeWeighIn(let id): return "wi-\(id)"
            }
        }
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    targetsSection
                    weighInsSection
                    resultSection
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
        .sheet(item: $pickerMode) { mode in
            ContainerPickerSheet { picked in handlePick(picked, mode: mode) }
                .environment(auth)
        }
        .sheet(isPresented: $showManager) {
            ContainersListView()
                .environment(auth)
                .onDisappear {
                    Task {
                        await listModel?.load()
                        reconcile()
                    }
                }
        }
        .task {
            if listModel == nil { listModel = ContainersListModel(auth: auth) }
            await listModel?.load()
            hydrateIfNeeded()
            reconcile()
        }
        .onChange(of: model.targets) { _, _ in persist() }
        .onChange(of: model.weighIns) { _, _ in persist() }
        .onChange(of: model.portionsOverride) { _, _ in persist() }
    }

    // MARK: - Sections

    /// "Divide into" card: one row per target container with a count stepper.
    @ViewBuilder
    private var targetsSection: some View {
        section(header: "Divide into") {
            if model.targets.isEmpty {
                emptyRow("Pick the containers to split into")
            } else {
                ForEach($model.targets) { $t in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.container.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.FG.primary)
                                .lineLimit(1)
                            Text("\(Int(t.container.tareWeightG.rounded())) g tare")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.FG.secondary)
                        }
                        Spacer()
                        Stepper(value: $t.count, in: 1...99) {
                            Text("×\(t.count)")
                                .font(.system(size: 14, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.FG.primary)
                        }
                        .tint(Theme.CTP.mauve)
                        .fixedSize()
                        Button { delete(target: t.id) } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.FG.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    divider
                }
            }
            addButton("Add container") { pickerMode = .addTarget }
            if model.containerCount > 0 {
                HStack {
                    Spacer()
                    Text("\(model.containerCount) container\(model.containerCount == 1 ? "" : "s")")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.FG.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    /// "Weigh-ins" card: one row per scale reading (container + gross grams).
    @ViewBuilder
    private var weighInsSection: some View {
        section(header: "Weigh-ins") {
            if model.weighIns.isEmpty {
                emptyRow("Add each container you put on the scale")
            } else {
                ForEach($model.weighIns) { $w in
                    HStack(spacing: 10) {
                        Button { pickerMode = .changeWeighIn(w.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w.container.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.FG.primary)
                                    .lineLimit(1)
                                Text("\(Int(w.container.tareWeightG.rounded())) g tare")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.FG.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        TextField(
                            "",
                            value: $w.grossGrams,
                            format: .number,
                            prompt: Text("0").foregroundStyle(Theme.FG.tertiary)
                        )
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(Theme.FG.primary)
                        .tint(Theme.CTP.mauve)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        Text("g")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.FG.secondary)
                        Button { delete(weighIn: w.id) } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.FG.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    divider
                }
            }
            addButton("Add weigh-in") { addWeighIn() }
        }
    }

    /// "Result" card: total net, portions stepper, per-portion, and fill targets.
    @ViewBuilder
    private var resultSection: some View {
        section(header: "Result") {
            resultRow("Total net food", value: model.totalNetGrams)
            divider
            HStack {
                Text("Portions")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.FG.primary)
                Spacer()
                Stepper(
                    value: Binding(get: { model.portions }, set: { model.portionsOverride = $0 }),
                    in: 1...99
                ) {
                    Text("\(model.portions)")
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.FG.primary)
                }
                .tint(Theme.CTP.mauve)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            divider
            resultRow("Per portion", value: model.perPortionGrams)
            divider
            fillTargetRows
        }
    }

    /// Fill-target row(s): a single line when tares are uniform, else per entry.
    @ViewBuilder
    private var fillTargetRows: some View {
        if model.containerCount > 0, model.perContainerNetGrams != nil {
            if model.targetTaresAreUniform, let entry = model.targets.first {
                resultRow("Fill each container to", value: model.targetGross(for: entry))
            } else {
                ForEach(model.targets) { entry in
                    resultRow("Fill \(entry.container.name) to", value: model.targetGross(for: entry))
                }
            }
        } else {
            resultRow("Fill each container to", value: nil)
        }
    }

    // MARK: - Actions

    /// Routes a picked container to the target list or a weigh-in per the mode.
    /// Inputs:
    ///   - c: the chosen container.
    ///   - mode: which selection the picker was fulfilling.
    private func handlePick(_ c: Container, mode: PickerMode) {
        switch mode {
        case .addTarget:
            if let idx = model.targets.firstIndex(where: { $0.container.id == c.id }) {
                model.targets[idx].count += 1
            } else {
                model.targets.append(.init(container: c, count: 1))
            }
        case .addWeighIn:
            model.weighIns.append(.init(container: c))
            rememberLastWeighIn(c)
        case .changeWeighIn(let id):
            if let idx = model.weighIns.firstIndex(where: { $0.id == id }) {
                model.weighIns[idx].container = c
                rememberLastWeighIn(c)
            }
        }
    }

    /// Appends a weigh-in, defaulting its container: the sole target container if
    /// there is exactly one distinct target, else the last-used weigh-in container,
    /// else opens the picker.
    private func addWeighIn() {
        let distinct = Set(model.targets.map { $0.container.id })
        if distinct.count == 1, let c = model.targets.first?.container {
            model.weighIns.append(.init(container: c))
            return
        }
        if let last = lastWeighInContainer() {
            model.weighIns.append(.init(container: last))
            return
        }
        pickerMode = .addWeighIn
    }

    /// Removes a target entry by id.
    /// Inputs:
    ///   - id: the target entry's id.
    private func delete(target id: UUID) {
        model.targets.removeAll { $0.id == id }
    }

    /// Removes a weigh-in by id.
    /// Inputs:
    ///   - id: the weigh-in's id.
    private func delete(weighIn id: UUID) {
        model.weighIns.removeAll { $0.id == id }
    }

    // MARK: - Persistence & reconcile

    /// Loads saved targets/weigh-ins/portions from `UserDefaults` once, matching
    /// stored container ids against the loaded list (dropping unknown ids).
    private func hydrateIfNeeded() {
        guard !hydrated else { return }
        hydrated = true
        guard case .loaded(let list) = listModel?.state ?? .idle else { return }
        let d = UserDefaults.standard
        if let data = d.data(forKey: "prep.targets"),
           let saved = try? JSONDecoder().decode([PersistedPrepTarget].self, from: data) {
            model.targets = saved.compactMap { s in
                guard let uid = UUID(uuidString: s.containerId),
                      let c = list.first(where: { $0.id == uid }) else { return nil }
                return PrepModel.TargetEntry(container: c, count: max(1, s.count))
            }
        }
        if let data = d.data(forKey: "prep.weighIns"),
           let saved = try? JSONDecoder().decode([PersistedPrepWeighIn].self, from: data) {
            model.weighIns = saved.compactMap { s in
                guard let uid = UUID(uuidString: s.containerId),
                      let c = list.first(where: { $0.id == uid }) else { return nil }
                return PrepModel.WeighIn(container: c, grossGrams: s.grossGrams)
            }
        }
        if d.object(forKey: "prep.portionsOverride") != nil {
            model.portionsOverride = d.integer(forKey: "prep.portionsOverride")
        }
    }

    /// Writes the current targets/weigh-ins/portions to `UserDefaults`.
    private func persist() {
        let d = UserDefaults.standard
        let t = model.targets.map { PersistedPrepTarget(containerId: $0.container.id.uuidString, count: $0.count) }
        let w = model.weighIns.map { PersistedPrepWeighIn(containerId: $0.container.id.uuidString, grossGrams: $0.grossGrams) }
        if let td = try? JSONEncoder().encode(t) { d.set(td, forKey: "prep.targets") }
        if let wd = try? JSONEncoder().encode(w) { d.set(wd, forKey: "prep.weighIns") }
        if let p = model.portionsOverride {
            d.set(p, forKey: "prep.portionsOverride")
        } else {
            d.removeObject(forKey: "prep.portionsOverride")
        }
    }

    /// Stores the given container as the last-used weigh-in default.
    /// Inputs:
    ///   - c: the container to remember.
    private func rememberLastWeighIn(_ c: Container) {
        UserDefaults.standard.set(c.id.uuidString, forKey: "prep.lastWeighInContainerId")
    }

    /// Resolves the last-used weigh-in container from the loaded list, if any.
    /// Outputs: the matching `Container`, or nil when unset/not loaded/deleted.
    private func lastWeighInContainer() -> Container? {
        guard let raw = UserDefaults.standard.string(forKey: "prep.lastWeighInContainerId"),
              let id = UUID(uuidString: raw),
              case .loaded(let list) = listModel?.state ?? .idle else { return nil }
        return list.first(where: { $0.id == id })
    }

    /// Refreshes container snapshots and drops deleted ones using the loaded list.
    private func reconcile() {
        guard case .loaded(let list) = listModel?.state ?? .idle else { return }
        model.reconcile(with: list)
    }

    // MARK: - Reusable views

    /// A thin separator used between card rows.
    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(height: 0.5)
    }

    /// A muted placeholder row shown when a section is empty.
    /// Inputs:
    ///   - text: the placeholder message.
    /// Outputs: a styled row `View`.
    private func emptyRow(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.FG.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// A mauve "add" button row.
    /// Inputs:
    ///   - title: the button label.
    ///   - action: the tap handler.
    /// Outputs: a styled button `View`.
    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .foregroundStyle(Theme.CTP.mauve)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Wraps a card-styled content block under an uppercase section header.
    /// Inputs:
    ///   - header: section title shown above the card.
    ///   - content: view builder for the card body.
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
    /// Inputs:
    ///   - label: left-aligned descriptive label.
    ///   - value: optional gram value; renders an em-dash placeholder when nil.
    /// Outputs: a styled row `View`.
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
