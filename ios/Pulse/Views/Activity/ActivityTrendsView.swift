import SwiftUI
import Charts

private let prBadgeCornerRadius: CGFloat = 5

/// Trends screen: period selector, headline time/frequency/calorie deltas,
/// a volume-over-time bar chart, a by-type breakdown, and strength top lifts.
struct ActivityTrendsView: View {
    @State private var model: ActivityTrendsModel

    /// Initializes the view with the shared auth session.
    /// - Parameter auth: The app's authenticated session.
    init(auth: AuthSession) {
        _model = State(initialValue: ActivityTrendsModel(auth: auth))
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CTPSegmented(selection: Binding(get: { model.period },
                                                    set: { model.setPeriodAndLoad($0) }),
                                 options: ActivityPeriod.allCases) { $0.label }
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, Theme.Layout.dockClearance)
            }
        }
        .navigationTitle("Trends")
        .navigationBarTitleDisplayMode(.inline)
        .task { if case .idle = model.state { await model.load() } }
    }

    /// Switches on `model.state` to render a loading spinner, an error view, or the
    /// full summary content (headline deltas, volume chart, by-group card, top lifts).
    /// - Returns: The view for the current load state.
    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView().tint(Theme.FG.secondary).frame(maxWidth: .infinity).padding(.top, 40)
        case let .failed(error):
            EmptyStateView(icon: "exclamationmark.triangle",
                           title: "Couldn't load trends",
                           description: error.userMessage)
        case let .loaded(s):
            headline(s)
            if !s.volumeSeries.isEmpty { volumeCard(s) }
            if !s.byGroup.isEmpty { byGroupCard(s) }
            if !s.topLifts.isEmpty { topLiftsCard(s) }
        }
    }

    /// Three headline metric tiles: time, sessions, and calories with period-over-period deltas.
    /// - Parameter s: The loaded activity summary.
    /// - Returns: An `HStack` of metric tile views.
    private func headline(_ s: ActivitySummary) -> some View {
        HStack(spacing: 10) {
            metricTile("Time",
                       value: s.totals.totalDurationMin.asDurationFromMinutes,
                       delta: s.deltas.totalDurationMin)
            metricTile("Sessions", value: "\(s.totals.workoutCount)", delta: s.deltas.workoutCount)
            metricTile("Calories",
                       value: "\(Int(s.totals.totalActiveEnergyCal.rounded()))",
                       delta: s.deltas.totalActiveEnergyCal)
        }
    }

    /// A single headline metric card showing label, value, and a coloured delta badge.
    /// - Parameters:
    ///   - label: The uppercased metric label (e.g. "Time").
    ///   - value: The formatted metric value string.
    ///   - delta: The period-over-period delta for colour and text.
    /// - Returns: A card-styled `VStack` metric tile.
    private func metricTile(_ label: String, value: String, delta: MetricDelta) -> some View {
        let text = ActivityTrendsModel.deltaText(delta)
        let up = (delta.pct ?? 0) >= 0
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).tracking(0.4)
                .textCase(.uppercase).foregroundStyle(Theme.FG.tertiary)
            Text(value).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.FG.primary)
            Text(text).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(text == "new" ? Theme.FG.tertiary : (up ? Theme.CTP.green : Theme.CTP.red))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12).ctpCard()
    }

    /// A card containing a Swift Charts bar chart of strength volume over the period's sub-buckets.
    /// - Parameter s: The loaded activity summary.
    /// - Returns: A padded card view with a title and bar chart.
    private func volumeCard(_ s: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("Volume over time")
            Chart(s.volumeSeries) { bucket in
                BarMark(x: .value("Date", bucket.bucketStart, unit: .day),
                        y: .value("Volume", bucket.volumeLbs))
                    .foregroundStyle(Theme.CTP.mauve)
                    .cornerRadius(Theme.Layout.barRadius)
            }
            .frame(height: 180)
        }
        .padding(16).ctpCard()
    }

    /// A card showing one bar per parent group (Weights/Cardio), with a legend listing
    /// each group's subtypes and their within-group share.
    /// - Parameter s: The loaded activity summary.
    /// - Returns: A padded card with the grouped bar and a per-subtype legend.
    private func byGroupCard(_ s: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("By group")
            Chart(s.byGroup) { group in
                BarMark(x: .value("Minutes", group.durationMin))
                    .foregroundStyle(ActivityGroup(rawValue: group.group)?.color ?? Theme.CTP.overlay1)
            }
            .chartXAxis(.hidden)
            .frame(height: 36)
            VStack(spacing: 8) {
                ForEach(s.byGroup) { group in
                    let ag = ActivityGroup(rawValue: group.group)
                    let color = ag?.color ?? Theme.CTP.overlay1
                    HStack(spacing: 8) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(ag?.displayName ?? group.group)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.FG.primary)
                        Spacer()
                        Text("\(Int(group.durationMin.rounded())) min · \(Int((group.share * 100).rounded()))%")
                            .font(.system(size: 12)).foregroundStyle(Theme.FG.tertiary)
                    }
                    ForEach(group.subtypes) { sub in
                        HStack(spacing: 8) {
                            Text(ActivityType.displayName(sub.activityType))
                                .font(.system(size: 12)).foregroundStyle(Theme.FG.secondary)
                            Spacer()
                            Text("\(Int(sub.durationMin.rounded())) min · \(Int((sub.share * 100).rounded()))%")
                                .font(.system(size: 11)).foregroundStyle(Theme.FG.tertiary)
                        }
                        .padding(.leading, 16)
                    }
                }
            }
        }
        .padding(16).ctpCard()
    }

    /// A card listing the top lifts by estimated 1RM, with a PR badge for all-time records.
    /// - Parameter s: The loaded activity summary.
    /// - Returns: A padded card view with one row per top lift.
    private func topLiftsCard(_ s: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("Strength · top lifts")
            VStack(spacing: 8) {
                ForEach(s.topLifts) { lift in
                    HStack {
                        Text(lift.exerciseTitle).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.FG.primary)
                        if lift.isPr {
                            Text("PR").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.CTP.base)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: prBadgeCornerRadius).fill(Theme.CTP.yellow))
                        }
                        Spacer()
                        Text("\(Int(lift.bestEst1rm.rounded())) lb e1RM")
                            .font(.system(size: 13)).foregroundStyle(Theme.FG.secondary)
                        Text("(\(lift.bestWeightLbs.clean)×\(lift.bestReps))")
                            .font(.system(size: 11)).foregroundStyle(Theme.FG.tertiary)
                    }
                }
            }
        }
        .padding(16).ctpCard()
    }

    /// A small uppercased section title for a card.
    /// - Parameter text: The label to display.
    /// - Returns: A full-width styled `Text` view.
    private func cardTitle(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8)
            .foregroundStyle(Theme.FG.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
