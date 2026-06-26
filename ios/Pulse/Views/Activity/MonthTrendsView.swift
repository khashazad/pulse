import SwiftUI

/// Drill-down screen for one calendar month: lists that month's weeks as
/// tappable `WeekRollupRow`s, navigating deeper to `WeekTrendsView`.
/// Navigation title shows the full month name and year derived from `anchor`.
/// Auth is resolved from the SwiftUI environment; `anchor` and the week
/// callback are the only initialisation parameters.
struct MonthTrendsView: View {
    @Environment(AuthSession.self) private var auth
    @State private var model: MonthTrendsModel?

    private let anchor: Date
    private let onOpenWeek: (Date) -> Void

    /// Initializes the view for a specific calendar month.
    /// - Parameters:
    ///   - anchor: A date inside the target calendar month.
    ///   - onOpenWeek: Called with the week's start date when the user taps a row.
    init(anchor: Date, onOpenWeek: @escaping (Date) -> Void) {
        self.anchor = anchor
        self.onOpenWeek = onOpenWeek
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            content
        }
        .navigationTitle(anchor.formatted(.dateTime.month(.wide).year()))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = MonthTrendsModel(auth: auth, anchor: anchor) }
            if let m = model, case .idle = m.state { await m.load() }
        }
    }

    /// Renders a loading spinner, error view, empty-week placeholder, or the weeks list.
    /// - Returns: The view for the current load state.
    @ViewBuilder private var content: some View {
        switch model?.state {
        case .none, .some(.idle), .some(.loading):
            ProgressView()
                .tint(Theme.FG.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        case let .some(.failed(error)):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load month",
                description: error.userMessage
            )
        case let .some(.loaded(summary)):
            if summary.totals.workoutCount == 0 {
                EmptyStateView(
                    icon: "calendar",
                    title: "No workouts",
                    description: "No workouts recorded for this month."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
                        summaryCard(summary)
                        WeekBreakdownSection(weeks: summary.weeks, onOpenWeek: onOpenWeek)
                        Spacer(minLength: Theme.Layout.dockClearance)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                }
            }
        }
    }

    /// A two-tile summary header for the month: total session count and total time.
    /// Mirrors the Trends headline tiles so the drill-down reads consistently.
    /// - Parameter s: The loaded month summary.
    /// - Returns: An `HStack` of two stat tiles.
    private func summaryCard(_ s: ActivitySummary) -> some View {
        HStack(spacing: 10) {
            summaryTile(
                "Sessions",
                "\(s.totals.workoutCount)"
            )
            summaryTile(
                "Time",
                s.totals.totalDurationMin.asDurationWithDays
            )
        }
    }

    /// A single labelled stat tile used by `summaryCard`.
    /// - Parameters:
    ///   - label: The uppercased metric label (e.g. "Sessions").
    ///   - value: The formatted metric value.
    /// - Returns: A card-styled tile filling the available width.
    private func summaryTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(Theme.FG.tertiary)
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.FG.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .ctpCard()
    }
}
