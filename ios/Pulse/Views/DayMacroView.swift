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
    @State private var model: DayMacroModel?
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
    /// Whether the pending-items panel (behind the count pill) is expanded.
    @State private var pendingExpanded = false
    /// Whether the meal-group delete confirmation dialog is presented.
    @State private var showMealDeleteConfirm = false
    /// The meal-group entries queued for deletion, pending dialog confirmation.
    /// Holds the exact items to remove: the whole group from a confirmed cluster
    /// row, or only the pending subset from the pending panel.
    @State private var mealDeletion: [FoodEntry] = []

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
        .transientConfirmation($savedMealName)
        .confirmationDialog(
            "Delete this meal's \(mealDeletion.count) entries? This can't be undone.",
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

    /// The underlying `FoodEntry`s for a grouped row (one for a single, all
    /// items for a meal group).
    /// - Parameter row: The grouped day row.
    /// - Returns: Its entries.
    private func entries(of row: DayRow) -> [FoodEntry] {
        switch row {
        case .single(let entry): return [entry]
        case .meal(let group): return group.items
        }
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

    /// "Confirm all" button shown when the day has pending (unconfirmed) entries.
    /// Confirms every pending entry on the day in one request.
    /// Inputs:
    ///   - pending: the day's pending entries.
    /// Outputs: composed button view.
    private func confirmAllBar(_ pending: [FoodEntry]) -> some View {
        PrimaryActionButton(
            title: "Confirm all (\(pending.count))",
            leading: .icon("checkmark.circle"),
            tint: Theme.CTP.green,
            disabled: model?.confirmState == .confirming
        ) {
            Task { await runConfirm(pending) }
        }
    }

    /// Confirms the given pending entries and routes the outcome: success
    /// reloads the day (handled by the model); a failure stores the entries and
    /// raises the retry alert.
    /// Inputs:
    ///   - entries: the pending entries to confirm.
    /// Outputs: nothing; mutates view state.
    private func runConfirm(_ entries: [FoodEntry]) async {
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

                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.top, 4)
        }
    }

    /// Tappable count pill summarizing pending items; toggles the panel.
    /// - Parameter count: Number of pending entries.
    /// - Returns: The pill view.
    private func pendingPill(count: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { pendingExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(count) pending")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: pendingExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.pending)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.pending.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) pending items, tap to \(pendingExpanded ? "collapse" : "expand")")
    }

    /// Expanded panel listing each pending row, swipeable to Approve or Delete,
    /// with an "Approve all" action.
    /// - Parameters:
    ///   - rows: The pending rows.
    ///   - allPending: The flat pending entries (for "Approve all").
    /// - Returns: The panel view.
    private func pendingPanel(_ rows: [DayRow], allPending: [FoodEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    SwipeActionsRow(actions: pendingRowActions(row)) {
                        switch row {
                        case .single(let entry): EntryRow(entry: entry)
                        case .meal(let group):   MealGroupRow(group: group)
                        }
                    }
                    if idx < rows.count - 1 {
                        Rectangle().fill(Theme.separator).frame(height: 0.5)
                    }
                }
            }
            .padding(.horizontal, 14)
            .ctpCard(tint: Theme.pending.opacity(0.08))

            confirmAllBar(allPending)
        }
    }

    /// Swipe actions for a pending row: Approve (confirm) and Delete (deferred).
    /// - Parameter row: The pending grouped row.
    /// - Returns: The trailing swipe actions.
    private func pendingRowActions(_ row: DayRow) -> [SwipeAction] {
        let pendingItems = entries(of: row).filter { !$0.isConfirmed }
        return [
            SwipeAction(label: "Approve", systemImage: "checkmark.circle", tint: Theme.CTP.green) {
                Task { await runConfirm(pendingItems) }
            },
            SwipeAction(label: "Delete", systemImage: "trash", tint: Theme.CTP.red, role: .destructive) {
                switch row {
                case .single(let entry):
                    model?.requestDelete([entry])
                case .meal:
                    mealDeletion = pendingItems
                    showMealDeleteConfirm = true
                }
            },
        ]
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
                SwipeActionsRow(actions: confirmedRowActions(row)) {
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

    /// Swipe actions for a confirmed row: Make Pending and Delete. A single-food
    /// delete defers immediately (with undo); a meal-group delete first asks for
    /// confirmation (it removes several entries at once).
    /// - Parameter row: The confirmed grouped row.
    /// - Returns: The trailing swipe actions.
    private func confirmedRowActions(_ row: DayRow) -> [SwipeAction] {
        [
            SwipeAction(label: "Pending", systemImage: "clock.arrow.circlepath", tint: Theme.pending) {
                Task { await runMakePending(entries(of: row)) }
            },
            SwipeAction(label: "Delete", systemImage: "trash", tint: Theme.CTP.red, role: .destructive) {
                switch row {
                case .single(let entry):
                    model?.requestDelete([entry])
                case .meal(let group):
                    mealDeletion = group.items
                    showMealDeleteConfirm = true
                }
            },
        ]
    }

    /// Runs a make-pending action and surfaces failure through the existing
    /// confirm-failure alert channel (reused for symmetry).
    /// - Parameter entries: The entries to make pending.
    /// - Returns: Nothing.
    private func runMakePending(_ entries: [FoodEntry]) async {
        guard let model else { return }
        model.resetPendingState()
        await model.makePending(entries)
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
