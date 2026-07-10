/// Day-detail screen for a single date.
/// Hosts the kcal hero ring, macro totals, and grouped entries (single foods + meal groups)
/// for one day, driven by `DayMacroModel`.
import SwiftUI

/// Renders a single day's summary: hero ring, macro chips, and grouped entries list.
/// Loads via `DayMacroModel` on appear / date change and on pull-to-refresh.
struct DayMacroView: View {
    let date: Date
    @Environment(AuthSession.self) private var auth
    @Environment(\.scenePhase) private var scenePhase
    // Not `private`: read by the `DayMacroView+Pending.swift` extension.
    @State var model: DayMacroModel?
    /// Whether the entries list is in multi-select mode.
    @State private var isSelecting = false
    /// Ids of the individual `FoodEntry`s currently selected for copying.
    @State private var selectedIds: Set<UUID> = []
    /// Whether the "copy to day" sheet is presented.
    @State private var showCopySheet = false
    /// Whether the destructive delete confirmation dialog is presented.
    @State private var showDeleteConfirm = false
    /// Entries still needing deletion after a partial failure (retry input).
    @State private var deleteRemainder: [FoodEntry] = []
    /// Size of the original delete selection — fixed denominator for the
    /// failure message across retries (per-run `deleteState` counts reset).
    @State private var deleteTotal = 0
    /// Whether the partial-failure alert (with Retry) is presented.
    @State private var showDeleteFailure = false
    /// Pending entries awaiting confirmation after a failed confirm (retry input).
    @State private var confirmRetry: [FoodEntry] = []
    /// Whether the confirm-failure alert (with Retry) is presented.
    @State private var showConfirmFailure = false
    /// Whether the "save selection as meal" sheet is presented.
    @State private var showSaveMealSheet = false
    /// Name of a just-saved meal, shown as a transient confirmation; nil hides it.
    @State private var savedMealName: String?
    // The pending-section state below is not `private`: it is read and mutated by
    // the `DayMacroView+Pending.swift` extension (pill/panel/swipe-action builders).
    /// Whether the pending-items panel (behind the count pill) is expanded.
    @State var pendingExpanded = false
    /// Whether the meal-group delete confirmation dialog is presented.
    @State var showMealDeleteConfirm = false
    /// The meal-group entries queued for deletion, pending dialog confirmation.
    /// Holds the exact items to remove: the whole group from a confirmed cluster
    /// row, or only the pending subset from the pending panel.
    @State var mealDeletion: [FoodEntry] = []
    /// Entries to retry making pending after a failed make-pending (retry input).
    @State var pendingRetry: [FoodEntry] = []
    /// Whether the make-pending-failure alert (with Retry) is presented.
    @State var showPendingFailure = false

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            Group {
                switch model?.state ?? .idle {
                case .idle, .loading:
                    ProgressView()
                        .tint(Theme.CTP.mauve)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let summary):
                    loadedBody(summary)
                case .failed(let error):
                    errorBody(error)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.BG.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { selectToolbar }
        .task(id: date) {
            if model == nil { model = DayMacroModel(date: date, auth: auth) }
            await model?.load()
        }
        .refreshable { await model?.load() }
        .sheet(isPresented: $showCopySheet) {
            if let model {
                CopyEntriesSheet(
                    model: model,
                    entries: selectedEntries(),
                    onCopied: {
                        exitSelection()
                        Task { await model.load() }
                    }
                )
            }
        }
        .sheet(isPresented: $showSaveMealSheet) {
            SaveAsMealSheet(items: selectedEntries().map { NewMealItem.from(entry: $0) }, auth: auth) { meal in
                exitSelection()
                savedMealName = meal.name
            }
        }
        .confirmationDialog(
            "Delete \(selectedIds.count) \(selectedIds.count == 1 ? "entry" : "entries")? This can't be undone.",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let entries = selectedEntries()
                deleteTotal = entries.count
                Task { await runDelete(entries) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't delete all entries", isPresented: $showDeleteFailure) {
            Button("Retry") {
                Task { await runDelete(deleteRemainder) }
            }
            Button("Cancel", role: .cancel) {
                deleteRemainder = []
                deleteTotal = 0
                exitSelection()
                Task { await model?.load() }
            }
        } message: {
            if case .failed(_, let error) = model?.deleteState {
                Text("Deleted \(deleteTotal - deleteRemainder.count) of \(deleteTotal). \(error.userMessage)")
            }
        }
        .alert("Couldn't confirm entries", isPresented: $showConfirmFailure) {
            Button("Retry") {
                Task { await runConfirm(confirmRetry) }
            }
            Button("Cancel", role: .cancel) {
                confirmRetry = []
            }
        } message: {
            if case .failed(let error) = model?.confirmState {
                Text(error.userMessage)
            }
        }
        .alert("Couldn't move entries to pending", isPresented: $showPendingFailure) {
            Button("Retry") {
                Task { await runMakePending(pendingRetry) }
            }
            Button("Cancel", role: .cancel) {
                pendingRetry = []
            }
        } message: {
            if case .failed(let error) = model?.pendingState {
                Text(error.userMessage)
            }
        }
        .alert(
            "Couldn't update this day",
            isPresented: Binding(
                get: { if case .failed = model?.excludeState { return true } else { return false } },
                set: { if !$0 { model?.resetExcludeState() } }
            )
        ) {
            Button("OK", role: .cancel) { model?.resetExcludeState() }
        } message: {
            if case .failed(let error) = model?.excludeState {
                Text(error.userMessage)
            }
        }
        .transientConfirmation($savedMealName)
        .confirmationDialog(
            "Delete this meal's \(mealDeletion.count) entries?",
            isPresented: $showMealDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                model?.requestDelete(mealDeletion)
                mealDeletion = []
            }
            Button("Cancel", role: .cancel) { mealDeletion = [] }
        }
        .undoSnackbar(
            isPresented: model?.pendingDelete != nil,
            message: undoMessage,
            onUndo: { model?.undoDelete() }
        )
        .onDisappear { Task { await model?.flushPendingDelete() } }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                Task { await model?.flushPendingDelete() }
            }
        }
    }

    /// Snackbar text for the current buffered delete (singular/plural aware).
    /// Returns an empty string when there is no buffered delete.
    private var undoMessage: String {
        guard let count = model?.pendingDelete?.entries.count else { return "" }
        return count == 1 ? "Entry deleted" : "\(count) entries deleted"
    }

    /// Toolbar toggle that enters/exits multi-select. Only meaningful once the
    /// day's summary has loaded.
    @ToolbarContentBuilder
    private var selectToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if case .loaded(let summary) = model?.state, !summary.entries.isEmpty {
                Button(isSelecting ? "Done" : "Select") {
                    if isSelecting { exitSelection() } else { isSelecting = true }
                }
                .foregroundStyle(Theme.CTP.mauve)
            }
        }
    }

    /// Leaves multi-select mode and clears the current selection.
    /// - Returns: Nothing.
    private func exitSelection() {
        isSelecting = false
        selectedIds = []
    }

    /// Resolves the currently selected ids back into their `FoodEntry` values from
    /// the loaded summary, preserving the day's original order.
    /// - Returns: The selected entries, or an empty array when nothing is loaded.
    private func selectedEntries() -> [FoodEntry] {
        guard case .loaded(let summary) = model?.state else { return [] }
        return summary.entries.filter { selectedIds.contains($0.id) }
    }

    /// Runs the delete loop over the given entries and routes the outcome:
    /// full success exits selection and reloads the day; a partial failure
    /// stores the remainder and raises the retry alert.
    /// Inputs:
    ///   - entries: the entries to delete (initial selection or a retry remainder).
    /// Outputs: nothing; mutates view state.
    private func runDelete(_ entries: [FoodEntry]) async {
        guard let model else { return }
        model.resetDeleteState()
        let remainder = await model.deleteEntries(entries)
        if remainder.isEmpty {
            deleteRemainder = []
            deleteTotal = 0
            exitSelection()
            await model.load()
        } else {
            deleteRemainder = remainder
            showDeleteFailure = true
        }
    }

    // Not `private`: called by the pending panel in the `DayMacroView+Pending.swift` extension.
    /// "Confirm all" button shown when the day has pending (unconfirmed) entries.
    /// Confirms every pending entry on the day in one request.
    /// Inputs:
    ///   - pending: the day's pending entries.
    /// Outputs: composed button view.
    func confirmAllBar(_ pending: [FoodEntry]) -> some View {
        PrimaryActionButton(
            title: "Confirm all (\(pending.count))",
            leading: .icon("checkmark.circle"),
            tint: Theme.CTP.green,
            disabled: model?.confirmState == .confirming
        ) {
            Task { await runConfirm(pending) }
        }
    }

    // Not `private`: called by pending-row Approve in the `DayMacroView+Pending.swift` extension.
    /// Confirms the given pending entries and routes the outcome: success
    /// reloads the day (handled by the model); a failure stores the entries and
    /// raises the retry alert.
    /// Inputs:
    ///   - entries: the pending entries to confirm.
    /// Outputs: nothing; mutates view state.
    func runConfirm(_ entries: [FoodEntry]) async {
        guard let model else { return }
        model.resetConfirmState()
        await model.confirmEntries(entries)
        if case .failed = model.confirmState {
            confirmRetry = entries
            showConfirmFailure = true
        } else {
            confirmRetry = []
        }
    }

    /// Navigation-bar title: "Today" / "Yesterday" / medium-formatted date.
    /// Outputs: localized title string for the navigation bar.
    private var title: String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }

    /// Body for the loaded state: hero ring, totals row, entries header, entries card.
    /// Inputs:
    ///   - summary: the loaded `DailySummary` for the date.
    /// Outputs: composed scrollable view for the day.
    @ViewBuilder
    private func loadedBody(_ summary: DailySummary) -> some View {
        // Group ALL entries once so multi-instance meals stay merged (grouping the
        // confirmed and pending slices separately would split a same-meal pair into
        // two rows), then partition the rows: any row with a pending item is pinned
        // to the Pending section at the top, the rest fall to the entries list below.
        let allRows = groupDayEntries(summary.entries)
        let pendingRows = allRows.filter(\.hasPendingItems)
        let confirmedRows = allRows.filter { !$0.hasPendingItems }
        let pending = summary.entries.filter { !$0.isConfirmed }
        // What the totals would read if every pending entry were confirmed.
        let projected = projectedTotals(consumed: summary.consumed, pending: pending)
        ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                heroRing(
                    consumed: summary.consumed.calories,
                    target: summary.target.calories,
                    projected: projected?.calories
                )
                .padding(.horizontal, 16)

                MacroTotalsRow(totals: summary.consumed, targets: summary.target, projected: projected)
                    .padding(.horizontal, 16)

                if !isSelecting, !pendingRows.isEmpty {
                    pendingPill(count: pending.count)
                        .padding(.horizontal, 16)
                    if pendingExpanded {
                        pendingPanel(pendingRows, allPending: pending)
                            .padding(.horizontal, 16)
                    }
                }

                if summary.entries.isEmpty {
                    entriesHeader(count: 0, kcal: 0)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                    EmptyStateView(
                        icon: "fork.knife",
                        title: "No entries logged",
                        description: "Anything you log will appear here."
                    )
                    .padding(.top, 8)
                } else if isSelecting {
                    entriesHeader(count: allRows.count, kcal: summary.consumed.calories)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                    selectableEntriesCard(summary.entries)
                        .padding(.horizontal, 16)
                    selectionActionBar
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                } else if !confirmedRows.isEmpty {
                    // Confirmed-only rows; pending rows render in the section above.
                    entriesHeader(count: confirmedRows.count, kcal: summary.consumed.calories)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                    clusteredEntries(confirmedRows)
                        .padding(.horizontal, 16)
                }

                if !isSelecting {
                    excludeToggle(summary)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                }

                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.top, 4)
        }
    }

    /// Flat, selectable list of the day's individual entries shown in multi-select
    /// mode. Unlike `entriesCard`, meals are not grouped — each underlying
    /// `FoodEntry` is independently selectable so the user copies exactly the
    /// items they want.
    /// Inputs:
    ///   - entries: all `FoodEntry`s for the day, in arrival order.
    /// Outputs: composed selectable card view.
    private func selectableEntriesCard(_ entries: [FoodEntry]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                Button {
                    toggleSelection(entry.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedIds.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(selectedIds.contains(entry.id) ? Theme.CTP.mauve : Theme.FG.tertiary)
                        EntryRow(entry: entry)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if idx < entries.count - 1 {
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                }
            }
        }
        .padding(.horizontal, 14)
        .ctpCard()
    }

    /// Action bar shown under the selectable list: count-aware Copy, Save as
    /// meal, and Delete buttons. Copy opens the backdating copy sheet; Save as
    /// meal opens the sheet that turns the selection into a saved meal template;
    /// Delete asks for confirmation before destructively removing the selected
    /// entries. All are disabled until at least one entry is selected.
    private var selectionActionBar: some View {
        let count = selectedIds.count
        return HStack(spacing: 10) {
            PrimaryActionButton(
                title: count == 0 ? "Copy" : "Copy \(count)…",
                leading: .icon("calendar.badge.plus"),
                disabled: count == 0
            ) {
                model?.resetCopyState()
                showCopySheet = true
            }
            PrimaryActionButton(
                title: count == 0 ? "Save as meal" : "Save as meal \(count)",
                leading: .icon("square.stack.3d.up"),
                disabled: count == 0
            ) {
                showSaveMealSheet = true
            }
            PrimaryActionButton(
                title: count == 0 ? "Delete" : "Delete \(count)",
                leading: .icon("trash"),
                tint: Theme.CTP.red,
                disabled: count == 0 || model?.deleteState == .deleting
            ) {
                showDeleteConfirm = true
            }
        }
    }

    /// Toggles whether the entry with the given id is part of the copy selection.
    /// Inputs:
    ///   - id: the `FoodEntry` id to toggle.
    /// Outputs: nothing; mutates `selectedIds`.
    private func toggleSelection(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    /// Backdrop + centered `MacroRing` used at the top of the day view.
    /// Inputs:
    ///   - consumed: kcal consumed today (confirmed only).
    ///   - target: daily kcal target.
    ///   - projected: kcal if pending entries were confirmed; drives the ring's
    ///     ghost arc. `nil` when there are no pending entries.
    /// Outputs: composed hero ring view.
    private func heroRing(consumed: Int, target: Int, projected: Int?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [Theme.CTP.mauve.opacity(0.10), Theme.CTP.base.opacity(0)],
                        center: .top,
                        startRadius: 0,
                        endRadius: 240
                    )
                )
            MacroRing(consumed: consumed, target: target, projected: projected)
                .padding(.vertical, 22)
        }
    }

    /// "Exclude this day from stats" toggle card shown at the bottom of a loaded
    /// day. Flipping it calls the model's optimistic `setExcluded`; while a save
    /// is in flight the toggle is disabled. An excluded day still renders here in
    /// full — the flag only affects how period averages/trends and charts treat
    /// it — with a one-line hint explaining that.
    /// Inputs:
    ///   - summary: the loaded `DailySummary`, whose `excluded` drives the toggle.
    /// Outputs: composed toggle card view.
    private func excludeToggle(_ summary: DailySummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { summary.excluded },
                set: { newValue in Task { await model?.setExcluded(newValue) } }
            )) {
                Text("Exclude this day from stats")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.FG.primary)
            }
            .tint(Theme.CTP.mauve)
            .disabled(model?.excludeState == .saving)

            Text(summary.excluded
                ? "This day is skipped in averages, trends, and charts."
                : "Turn on for days you forgot to fully log.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.FG.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .ctpCard()
    }

    /// Small "Entries" caption row above the entries card with count and kcal total.
    /// Inputs:
    ///   - count: number of grouped rows in the entries card.
    ///   - kcal: total kcal consumed.
    /// Outputs: composed header view.
    private func entriesHeader(count: Int, kcal: Int) -> some View {
        HStack {
            Text("Entries")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Theme.FG.secondary)
            Spacer()
            Text("\(count) · \(kcal) cal")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.FG.tertiary)
        }
    }

    /// Stack of per-occasion cards, one per time-proximity cluster. Cards alternate
    /// between a mauve-tinted and a plain surface so adjacent logging bursts read as
    /// distinct blocks, making mis-timed or duplicate entries easy to spot.
    /// Inputs:
    ///   - rows: the day's entries already folded into `DayRow`s by `groupDayEntries`
    ///     (sorted ascending by representative time).
    /// Outputs: composed stack of cluster cards.
    private func clusteredEntries(_ rows: [DayRow]) -> some View {
        let clusters = clusterByProximity(rows)
        return VStack(spacing: 10) {
            ForEach(Array(clusters.enumerated()), id: \.element.id) { idx, cluster in
                clusterCard(cluster, tinted: idx.isMultiple(of: 2))
            }
        }
    }

    /// One cluster's card: its rows (single foods + meal groups) stacked with
    /// hairline separators, on a tinted or plain surface.
    /// Inputs:
    ///   - cluster: the proximity cluster to render.
    ///   - tinted: whether to apply the mauve wash (alternated by the caller).
    /// Outputs: composed card view.
    private func clusterCard(_ cluster: DayCluster, tinted: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(cluster.rows.enumerated()), id: \.element.id) { idx, row in
                SwipeActionsRow(
                    actions: confirmedRowActions(row),
                    surfaceTint: tinted ? Theme.CTP.mauve.opacity(0.10) : nil
                ) {
                    // Rows here are confirmed-only; pending entries render in the
                    // pending panel behind the count pill above.
                    Group {
                        switch row {
                        case .single(let entry): EntryRow(entry: entry)
                        case .meal(let group):   MealGroupRow(group: group)
                        }
                    }
                }
                if idx < cluster.rows.count - 1 {
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                }
            }
        }
        .padding(.horizontal, 14)
        .ctpCard(tint: tinted ? Theme.CTP.mauve.opacity(0.10) : nil)
    }

    /// Body for the failed state. Renders a "no targets set" hint for `.notFound`,
    /// otherwise a generic retry-able error placeholder.
    /// Inputs:
    ///   - error: the load error.
    /// Outputs: composed empty-state view with a Retry action.
    @ViewBuilder
    private func errorBody(_ error: PulseError) -> some View {
        VStack {
            switch error {
            case .notFound:
                EmptyStateView(
                    icon: "target",
                    title: "No targets set",
                    description: "Set targets in the server to start tracking.",
                    action: { Task { await model?.load() } },
                    actionLabel: "Retry"
                )
            default:
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "Couldn't load",
                    description: error.userMessage,
                    action: { Task { await model?.load() } },
                    actionLabel: "Retry"
                )
            }
        }
    }
}
