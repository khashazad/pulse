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
        .task(id: date) {
            if model == nil { model = DayMacroModel(date: date, auth: auth) }
            await model?.load()
        }
        .refreshable { await model?.load() }
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
        ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                heroRing(consumed: summary.consumed.calories, target: summary.target.calories)
                    .padding(.horizontal, 16)

                MacroTotalsRow(totals: summary.consumed, targets: summary.target)
                    .padding(.horizontal, 16)

                entriesHeader(count: groupDayEntries(summary.entries).count, kcal: summary.consumed.calories)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                if summary.entries.isEmpty {
                    EmptyStateView(
                        icon: "fork.knife",
                        title: "No entries logged",
                        description: "Anything you log will appear here."
                    )
                    .padding(.top, 8)
                } else {
                    entriesCard(summary.entries)
                        .padding(.horizontal, 16)
                }

                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.top, 4)
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

    /// Card listing entries for the day, grouping multi-item meals into `MealGroupRow`.
    /// Inputs:
    ///   - entries: all `FoodEntry`s for the day.
    /// Outputs: composed card view.
    private func entriesCard(_ entries: [FoodEntry]) -> some View {
        let rows = groupDayEntries(entries)
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                Group {
                    switch row {
                    case .single(let entry):
                        EntryRow(entry: entry)
                    case .meal(let group):
                        MealGroupRow(group: group)
                    }
                }
                if idx < rows.count - 1 {
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                }
            }
        }
        .padding(.horizontal, 14)
        .ctpCard()
    }

    /// Body for the failed state. Renders a "no targets set" hint for `.notFound`,
    /// otherwise a generic retry-able error placeholder.
    /// Inputs:
    ///   - error: the load error.
    /// Outputs: composed empty-state view with a Retry action.
    @ViewBuilder
    private func errorBody(_ error: DietTrackerError) -> some View {
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
