import SwiftUI
import Charts

private let prBadgeCornerRadius: CGFloat = 5

/// Trends screen: Year / Month period selector (default Year), two headline
/// metric tiles (Time and Sessions with period-over-period delta badges), a
/// flat by-type breakdown card, a tappable period breakdown list (months for
/// Year, weeks for Month), and a Strength section with a volume chart and top lifts.
struct ActivityTrendsView: View {
    @State private var model: ActivityTrendsModel

    /// Called when the user taps the manage-types toolbar button.
    private let onManageTypes: () -> Void
    /// Called when the user taps a month row in the Year period view.
    private let onOpenMonth: (Date) -> Void
    /// Called when the user taps a week row in the Month period view.
    private let onOpenWeek: (Date) -> Void
    /// Called when the user taps the all-activities toolbar button.
    private let onOpenFeed: () -> Void

    /// Initializes the view with the shared auth session and navigation callbacks.
    /// - Parameters:
    ///   - auth: The app's authenticated session.
    ///   - onManageTypes: Invoked when the user taps the toolbar button to open
    ///     the activity-types management screen.
    ///   - onOpenMonth: Invoked with the month's start date when the user taps a
    ///     month row in the Year period breakdown.
    ///   - onOpenWeek: Invoked with the week's start date when the user taps a
    ///     week row in the Month period breakdown.
    ///   - onOpenFeed: Invoked when the user taps the all-activities toolbar button
    ///     to open the paginated workout feed.
    init(
        auth: AuthSession,
        onManageTypes: @escaping () -> Void,
        onOpenMonth: @escaping (Date) -> Void,
        onOpenWeek: @escaping (Date) -> Void,
        onOpenFeed: @escaping () -> Void
    ) {
        _model = State(initialValue: ActivityTrendsModel(auth: auth))
        self.onManageTypes = onManageTypes
        self.onOpenMonth = onOpenMonth
        self.onOpenWeek = onOpenWeek
        self.onOpenFeed = onOpenFeed
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CTPSegmented(
                        selection: Binding(
                            get: { model.period },
                            set: { model.setPeriodAndLoad($0) }
                        ),
                        options: [ActivityPeriod.year, .month]
                    ) { $0.label }
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, Theme.Layout.dockClearance)
            }
        }
        .navigationTitle("Trends")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onOpenFeed()
                } label: {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onManageTypes()
                } label: {
                    Image(systemName: "tag")
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
        }
        .task { if case .idle = model.state { await model.load() } }
    }

    /// Switches on `model.state` to render a loading spinner, an error view, or the
    /// full summary content (headline, by-type card, period list, Strength section).
    /// - Returns: The view for the current load state.
    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .tint(Theme.FG.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        case let .failed(error):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load trends",
                description: error.userMessage
            )
        case let .loaded(s):
            headline(s)
            if !s.byType.isEmpty { byTypeCard(s) }
            periodBreakdownCard(s)
            strengthSection(s)
            if !s.energyBalance.isEmpty {
                EnergyBalanceSection(buckets: s.energyBalance)
            }
        }
    }

    // MARK: - Headline

    /// Two headline metric tiles: Time and Sessions with period-over-period delta badges.
    /// For the Year period, Time is formatted as days+hours+minutes and Sessions
    /// includes a sessions-per-month caption (`workoutCount / 12` rounded).
    /// - Parameter s: The loaded activity summary.
    /// - Returns: An `HStack` of two metric tile views.
    private func headline(_ s: ActivitySummary) -> some View {
        HStack(spacing: 10) {
            let timeValue = model.period == .year
                ? s.totals.totalDurationMin.asDurationWithDays
                : s.totals.totalDurationMin.asDurationFromMinutes
            metricTile("Time", value: timeValue, delta: s.deltas.totalDurationMin)
            let perMonth = model.period == .year
                ? "\(max(1, s.totals.workoutCount) / 12)/mo"
                : nil
            metricTile(
                "Sessions",
                value: "\(s.totals.workoutCount)",
                delta: s.deltas.workoutCount,
                caption: perMonth
            )
        }
    }

    /// A single headline metric card showing label, value, delta badge, and optional caption.
    /// - Parameters:
    ///   - label: The uppercased metric label (e.g. "Time").
    ///   - value: The formatted metric value string.
    ///   - delta: The period-over-period delta for colour and percentage badge.
    ///   - caption: Optional small secondary annotation shown beneath the delta.
    /// - Returns: A card-styled `VStack` metric tile.
    private func metricTile(
        _ label: String,
        value: String,
        delta: MetricDelta,
        caption: String? = nil
    ) -> some View {
        let text = ActivityTrendsModel.deltaText(delta)
        let up = (delta.pct ?? 0) >= 0
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(Theme.FG.tertiary)
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.FG.primary)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    text == "new"
                        ? Theme.FG.tertiary
                        : (up ? Theme.CTP.green : Theme.CTP.red)
                )
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.FG.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .ctpCard()
    }

    // MARK: - By Type Card

    /// A card titled "By type" listing each type with a colored dot, display name,
    /// and duration + share percentage. Includes a thin proportional bar chart.
    /// - Parameter s: The loaded activity summary.
    /// - Returns: A padded card view with chart and per-type rows.
    private func byTypeCard(_ s: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("By type")
            Chart(s.byType) { entry in
                BarMark(x: .value("Minutes", entry.durationMin))
                    .foregroundStyle(ActivityType.color(entry.activityType))
            }
            .chartXAxis(.hidden)
            .frame(height: 28)
            VStack(spacing: 8) {
                ForEach(s.byType) { entry in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(ActivityType.color(entry.activityType))
                            .frame(width: 8, height: 8)
                        Text(ActivityType.displayName(entry.activityType))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.FG.primary)
                        Spacer()
                        Text(
                            "\(Int(entry.durationMin.rounded())) min"
                            + " · \(Int((entry.share * 100).rounded()))%"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.FG.tertiary)
                    }
                }
            }
        }
        .padding(16)
        .ctpCard()
    }

    // MARK: - Period Breakdown

    /// A card listing sub-period breakdowns: months (for Year) or weeks (for Month).
    /// Month rows navigate to `MonthTrendsView`; week rows navigate to `WeekTrendsView`.
    /// - Parameter s: The loaded activity summary.
    /// - Returns: A padded card with one tappable row per sub-period, or `EmptyView` when empty.
    @ViewBuilder
    private func periodBreakdownCard(_ s: ActivitySummary) -> some View {
        if model.period == .year, !s.months.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("By month")
                VStack(spacing: 8) {
                    ForEach(s.months) { month in
                        monthRow(month)
                    }
                }
            }
            .padding(16)
            .ctpCard()
        } else if model.period == .month, !s.weeks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("By week")
                VStack(spacing: 8) {
                    ForEach(s.weeks) { week in
                        Button {
                            onOpenWeek(week.weekStart)
                        } label: {
                            WeekRollupRow(week: week)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .ctpCard()
        }
    }

    /// A tappable month-breakdown row showing the abbreviated month, session count, and time.
    /// Tapping navigates to the month's week drill-down via `onOpenMonth`.
    /// - Parameter month: The `MonthRollup` to render.
    /// - Returns: A plain-style `Button` wrapping a full-width `HStack` row.
    private func monthRow(_ month: MonthRollup) -> some View {
        Button {
            onOpenMonth(month.monthStart)
        } label: {
            HStack {
                Text(month.monthStart.formatted(.dateTime.month(.abbreviated)))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.FG.primary)
                    .frame(width: 36, alignment: .leading)
                Text("\(month.sessionCount) sessions")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.FG.secondary)
                Spacer()
                Text(month.durationMin.asDurationFromMinutes)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.FG.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Strength Section

    /// A "Strength" section grouping the volume chart and top-lifts card.
    /// Rendered only when at least one of `volumeSeries` or `topLifts` is non-empty.
    /// - Parameter s: The loaded activity summary.
    /// - Returns: A `VStack` section with a heading and the strength-specific cards.
    @ViewBuilder
    private func strengthSection(_ s: ActivitySummary) -> some View {
        if !s.volumeSeries.isEmpty || !s.topLifts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Strength")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.FG.secondary)
                if !s.volumeSeries.isEmpty { volumeCard(s) }
                if !s.topLifts.isEmpty { topLiftsCard(s) }
            }
        }
    }

    // MARK: - Strength Cards

    /// A card containing a Swift Charts bar chart of strength volume over the period's
    /// sub-buckets.
    /// - Parameter s: The loaded activity summary.
    /// - Returns: A padded card view with a title and bar chart.
    private func volumeCard(_ s: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("Volume over time")
            Chart(s.volumeSeries) { bucket in
                BarMark(
                    x: .value("Date", bucket.bucketStart, unit: .day),
                    y: .value("Volume", bucket.volumeLbs)
                )
                .foregroundStyle(Theme.CTP.mauve)
                .cornerRadius(Theme.Layout.barRadius)
            }
            .frame(height: 180)
        }
        .padding(16)
        .ctpCard()
    }

    /// A card listing the top lifts by estimated 1RM, with a PR badge for all-time records.
    /// - Parameter s: The loaded activity summary.
    /// - Returns: A padded card view with one row per top lift.
    private func topLiftsCard(_ s: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("Top lifts")
            VStack(spacing: 8) {
                ForEach(s.topLifts) { lift in
                    HStack {
                        Text(lift.exerciseTitle)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.FG.primary)
                        if lift.isPr {
                            Text("PR")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.CTP.base)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: prBadgeCornerRadius)
                                        .fill(Theme.CTP.yellow)
                                )
                        }
                        Spacer()
                        Text("\(Int(lift.bestEst1rm.rounded())) lb e1RM")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.FG.secondary)
                        Text("(\(lift.bestWeightLbs.clean)×\(lift.bestReps))")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.FG.tertiary)
                    }
                }
            }
        }
        .padding(16)
        .ctpCard()
    }

    // MARK: - Shared

    /// A small uppercased section title for a card.
    /// - Parameter text: The label to display.
    /// - Returns: A full-width styled `Text` view.
    private func cardTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.FG.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
