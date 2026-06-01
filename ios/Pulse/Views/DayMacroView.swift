/// Day-detail screen for a single date.
/// Hosts the kcal hero ring, macro totals, and grouped entries (single foods + meal groups)
/// for one day, driven by `DayMacroModel`. Also defines the reusable `EmptyStateView`
/// used by the other intake/meals screens for empty/error states.
import SwiftUI

/// Renders a single day's summary: hero ring, macro chips, and grouped entries list.
/// Loads via `DayMacroModel` on appear / date change and on pull-to-refresh.
struct DayMacroView: View {
    let date: Date
    @Environment(AuthSession.self) private var auth
    @State private var model: DayMacroModel?
    /// Whether the entries list is in multi-select mode.
    @State private var isSelecting = false
    /// Ids of the individual `FoodEntry`s currently selected for copying.
    @State private var selectedIds: Set<UUID> = []
    /// Whether the "copy to day" sheet is presented.
    @State private var showCopySheet = false

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
        // Group once: reused by the header count and the (non-select) entries card.
        let rows = groupDayEntries(summary.entries)
        ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                heroRing(consumed: summary.consumed.calories, target: summary.target.calories)
                    .padding(.horizontal, 16)

                MacroTotalsRow(totals: summary.consumed, targets: summary.target)
                    .padding(.horizontal, 16)

                entriesHeader(count: rows.count, kcal: summary.consumed.calories)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                if summary.entries.isEmpty {
                    EmptyStateView(
                        icon: "fork.knife",
                        title: "No entries logged",
                        description: "Anything you log will appear here."
                    )
                    .padding(.top, 8)
                } else if isSelecting {
                    selectableEntriesCard(summary.entries)
                        .padding(.horizontal, 16)
                    copyActionBar
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                } else {
                    clusteredEntries(rows)
                        .padding(.horizontal, 16)
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

    /// Action bar shown under the selectable list: a count + a "Copy to day…"
    /// button that opens the backdating copy sheet. Disabled until at least one
    /// entry is selected.
    private var copyActionBar: some View {
        let count = selectedIds.count
        return Button {
            model?.resetCopyState()
            showCopySheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                Text(count == 0 ? "Select items to copy" : "Copy \(count) to day…")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Theme.CTP.mauve)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: Theme.Layout.cardRadius, style: .continuous)
                    .fill(Theme.CTP.mauve.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.cardRadius, style: .continuous)
                    .strokeBorder(Theme.CTP.mauve.opacity(0.30), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.5 : 1)
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
    ///   - consumed: kcal consumed today.
    ///   - target: daily kcal target.
    /// Outputs: composed hero ring view.
    private func heroRing(consumed: Int, target: Int) -> some View {
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
            MacroRing(consumed: consumed, target: target)
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
                Group {
                    switch row {
                    case .single(let entry):
                        EntryRow(entry: entry)
                    case .meal(let group):
                        MealGroupRow(group: group)
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

/// Modal sheet for copying a set of existing entries onto a chosen day. Wraps the
/// shared `BackdateSelector` (defaulting to Today, since the common case is
/// "carry yesterday's items into today") and a confirm button that calls
/// `DayMacroModel.copyEntries`, reporting progress / partial-skip / failure
/// inline and dismissing on success.
struct CopyEntriesSheet: View {
    @Bindable var model: DayMacroModel
    let entries: [FoodEntry]
    /// Invoked after a successful copy so the host can leave select mode and refresh.
    let onCopied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date = Date()
    /// Entries still needing to be copied. Seeded from `entries` on first appear,
    /// then narrowed to the remainder after a partial failure so a retry only
    /// re-sends what hasn't already succeeded (no duplication).
    @State private var pending: [FoodEntry]?

    /// Whether a prior attempt failed partway, so the action becomes a retry of
    /// just the remaining entries.
    private var isRetry: Bool {
        if case .failed = model.copyState { return true }
        return false
    }

    /// The entries the next confirm will attempt (the full set on the first run,
    /// the remainder after a partial failure).
    private var work: [FoodEntry] { pending ?? entries }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.primary.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    Text("Copy \(work.count) item\(work.count == 1 ? "" : "s") to which day?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.FG.secondary)

                    BackdateSelector(date: $date)
                        .padding(14)
                        .ctpCard()

                    statusRow

                    Spacer()

                    confirmButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .navigationTitle("Copy entries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.primary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
            .onAppear { if pending == nil { pending = entries } }
        }
    }

    /// Inline status line reflecting the model's `copyState`: a partial-failure
    /// notice (telling the user how many already saved, so a retry is understood
    /// to resume rather than duplicate) or an "all skipped" notice. Full success
    /// dismisses the sheet via the confirm action, so it shows nothing here.
    @ViewBuilder
    private var statusRow: some View {
        switch model.copyState {
        case .failed(let copied, let error):
            VStack(alignment: .leading, spacing: 4) {
                Label(error.userMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.CTP.red)
                if copied > 0 {
                    Text("\(copied) already saved — retry copies only the remaining \(work.count).")
                        .foregroundStyle(Theme.FG.tertiary)
                }
            }
            .font(.system(size: 12))
        case .finished(let copied, let skipped) where copied == 0 && skipped > 0:
            Label("Nothing to copy — \(skipped) item\(skipped == 1 ? "" : "s") had no recreatable source.", systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.CTP.peach)
        default:
            EmptyView()
        }
    }

    /// Confirm button that triggers the copy; shows a spinner while copying,
    /// narrows `pending` to the remainder on partial failure, and dismisses only
    /// once at least one entry has actually been copied.
    private var confirmButton: some View {
        let isCopying = model.copyState == .copying
        let label = isCopying ? "Copying…" : (isRetry ? "Retry \(work.count) remaining" : "Copy entries")
        return Button {
            Task {
                let remaining = await model.copyEntries(work, to: date)
                pending = remaining
                if case .finished(let copied, _) = model.copyState, copied > 0 {
                    onCopied()
                    dismiss()
                }
            }
        } label: {
            HStack(spacing: 8) {
                if isCopying {
                    ProgressView().tint(Theme.CTP.mauve)
                }
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Theme.CTP.mauve)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: Theme.Layout.cardRadius, style: .continuous)
                    .fill(Theme.CTP.mauve.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.cardRadius, style: .continuous)
                    .strokeBorder(Theme.CTP.mauve.opacity(0.30), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isCopying || work.isEmpty)
        .padding(.bottom, 12)
    }
}

/// Reusable empty/error placeholder with an icon glyph, title, description, and optional action button.
/// Used by every list-style screen for the empty / load-failed states.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let description: String
    var action: (() -> Void)? = nil
    var actionLabel: String = "Retry"

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.CTP.mauve.opacity(0.10))
                    .frame(width: 64, height: 64)
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Theme.CTP.mauve)
            }
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.FG.primary)
            Text(description)
                .font(.system(size: 14))
                .foregroundStyle(Theme.FG.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            if let action {
                Button(actionLabel, action: action)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.CTP.mauve)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}
