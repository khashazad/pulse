/// Multi-container meal-prep portioning screen.
///
/// Hosts `PrepView`: the user chooses the target containers to divide a batch
/// into (a list, or one container with a count), records one or more weigh-ins
/// (gross scale readings, each minus its container's tare), and reads back the
/// total net food, an even per-container fill target, and a decoupled per-portion
/// serving size. Reuses `ContainerPickerSheet` for selection, drives the
/// container-manager sheet, and persists in-progress state to `UserDefaults`.
import SwiftUI

/// Top-level screen for portioning one cooked batch across multiple containers.
struct PrepView: View {
    @Environment(AuthSession.self) private var auth
    @State private var model = PrepModel()
    @State private var listModel: ContainersListModel?
    @State private var pickerMode: PickerMode?
    @State private var showManager = false
    @State private var managerReloadTask: Task<Void, Never>?
    /// Tracks which weigh-in's gross-grams field holds the decimal-pad keyboard,
    /// so the keyboard toolbar's Done button can resign it (the decimal pad has
    /// no return key and this screen is not a dismissible sheet).
    @FocusState private var focusedWeighIn: UUID?
    @State private var batchModel = BatchCompositionModel()
    @State private var foodSearchModel: FoodSearchModel?
    @State private var showFoodSearch = false

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
                    foodsSection
                }
                .padding(.top, 16)
                .padding(.bottom, Theme.Layout.dockClearance)
            }
            .scrollDismissesKeyboard(.interactively)
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
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedWeighIn = nil }
                    .foregroundStyle(Theme.CTP.mauve)
            }
        }
        .sheet(item: $pickerMode) { mode in
            ContainerPickerSheet { picked in handlePick(picked, mode: mode) }
                .environment(auth)
        }
        .sheet(isPresented: $showFoodSearch) {
            if let fm = foodSearchModel {
                FoodSearchSheet(model: fm, containers: loadedContainers) { item in
                    batchModel.add(item)
                    model.saveBatchItems(batchModel.items)
                }
            }
        }
        .sheet(isPresented: $showManager) {
            ContainersListView()
                .environment(auth)
                .onDisappear {
                    managerReloadTask?.cancel()
                    managerReloadTask = Task {
                        await listModel?.load()
                        if Task.isCancelled { return }
                        hydrateIfNeeded()
                        model.reconcileIfLoaded(loadedListOrNil)
                    }
                }
        }
        .task {
            if listModel == nil { listModel = ContainersListModel(auth: auth) }
            if foodSearchModel == nil { foodSearchModel = FoodSearchModel(auth: auth) }
            await listModel?.load()
            hydrateIfNeeded()
            model.reconcileIfLoaded(loadedListOrNil)
        }
        .onChange(of: model.targets) { _, _ in model.persist() }
        .onChange(of: model.weighIns) { _, _ in model.persist() }
        .onChange(of: model.portionsOverride) { _, _ in model.persist() }
    }

    // MARK: - Sections

    /// "Divide into" card: one row per target container with a count stepper.
    @ViewBuilder
    private var targetsSection: some View {
        SectionCard(header: "Divide into") {
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
        SectionCard(header: "Weigh-ins") {
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
                        .focused($focusedWeighIn, equals: w.id)
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
        SectionCard(header: "Result") {
            resultRow("Total net food", value: model.totalNetGrams)
            if model.totalNetGrams != nil, model.hasUnenteredWeighIns {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("Some weigh-ins are blank, total is partial")
                        .font(.system(size: 11))
                    Spacer()
                }
                .foregroundStyle(Theme.FG.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
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
                // Safe: targetTaresAreUniform guarantees every entry shares a tare, so any works.
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

    /// "Foods in this batch" card: searched food items with per-item macros, a
    /// running batch total, and an add button that opens the food search sheet.
    @ViewBuilder
    private var foodsSection: some View {
        SectionCard(header: "Foods in this batch") {
            if batchModel.items.isEmpty {
                emptyRow("Search and add foods to this batch")
            } else {
                ForEach(batchModel.items) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.FG.primary)
                                .lineLimit(1)
                            Text(macroLine(item.macros))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.FG.secondary)
                        }
                        Spacer()
                        Button {
                            batchModel.remove(id: item.id)
                            model.saveBatchItems(batchModel.items)
                        } label: {
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
                HStack {
                    Text("Batch total")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.FG.primary)
                    Spacer()
                    Text(macroLine(batchModel.total))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.CTP.mauve)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                divider
            }
            addButton("Add food") { showFoodSearch = true }
        }
    }

    /// The loaded container list, or empty when not yet loaded.
    private var loadedContainers: [Container] {
        if case .loaded(let list) = listModel?.state ?? .idle { return list }
        return []
    }

    /// Formats a macro total as a compact single line.
    /// Inputs:
    ///   - m: the macros to format.
    /// Outputs: e.g. "260 kcal · P 5 · C 56 · F 1".
    private func macroLine(_ m: MacroTotals) -> String {
        "\(m.calories) kcal · P \(Int(m.proteinG)) · C \(Int(m.carbsG)) · F \(Int(m.fatG))"
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
        case .changeWeighIn(let id):
            if let idx = model.weighIns.firstIndex(where: { $0.id == id }) {
                model.weighIns[idx].container = c
            }
        }
    }

    /// Opens the container picker to add a weigh-in. Always presents the picker so
    /// the user chooses which container is on the scale, rather than auto-filling.
    private func addWeighIn() {
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

    /// The loaded container list, or nil when it has not yet loaded — used to gate
    /// the model's hydrate/reconcile so they no-op until containers are available.
    private var loadedListOrNil: [Container]? {
        if case .loaded(let list) = listModel?.state ?? .idle { return list }
        return nil
    }

    /// Delegates hydration to `PrepModel`; reseeds the batch composition state only
    /// when the model actually hydrated (returns the persisted items), matching the
    /// prior behavior of restoring batch items in the same pass as targets/weigh-ins.
    private func hydrateIfNeeded() {
        if let items = model.hydrateIfNeeded(matching: loadedListOrNil) {
            batchModel = BatchCompositionModel(items: items)
        }
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
