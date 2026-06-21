/// Trends sub-tab of the Measures screen.
///
/// Defines `WeightChartRange` (7d/30d/1y windows for the chart), hosts
/// `WeightTrendsView` which renders a Swift Charts weight-over-time card
/// (with regression dashed line and target rule) plus an Analytics card with
/// estimated maintenance kcal, recent trend, and ETA-to-target derived from
/// `WeightTrendsModel` + `UserTargetsStore`. The linear-fit overlay uses
/// `WeightTrendsModel.regressionLine(for:unit:)` and its `RegressionLine` type.
import SwiftUI
import Charts

/// Selectable time window for the weight-over-time chart.
enum WeightChartRange: String, CaseIterable, Hashable {
    case d7, d30, y1

    var days: Int {
        switch self {
        case .d7: return 7
        case .d30: return 30
        case .y1: return 365
        }
    }

    var label: String {
        switch self {
        case .d7: return "7d"
        case .d30: return "30d"
        case .y1: return "1y"
        }
    }
}

/// Trends screen showing a weight-over-time chart plus analytics derived from logs.
struct WeightTrendsView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(UserTargetsStore.self) private var targetsStore
    @State private var model: WeightTrendsModel?
    @State private var weightChartRange: WeightChartRange = .d30

    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            Group {
                switch model?.analytics ?? .idle {
                case .idle, .loading:
                    ProgressView().tint(Theme.CTP.mauve)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let result):
                    loadedBody(result)
                case .failed(let err):
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Couldn't load",
                        description: err.userMessage,
                        action: { Task { await model?.load() } },
                        actionLabel: "Retry"
                    )
                }
            }
        }
        .task {
            if model == nil { model = WeightTrendsModel(auth: auth, targetsStore: targetsStore) }
            await model?.load()
        }
        .onChange(of: targetsStore.targets?.targetWeightLb) { _, _ in
            model?.recomputeAnalytics()
        }
        .refreshable { await model?.load() }
    }

    /// Renders the loaded chart + analytics layout.
    ///
    /// Inputs:
    /// - result: precomputed analytics from the model.
    ///
    /// Outputs: the composed scroll view.
    @ViewBuilder
    private func loadedBody(_ result: WeightAnalyticsResult) -> some View {
        let displayUnit = WeightUnit(rawValue: displayUnitRaw) ?? .lb
        ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                weightOverTimeCard(entries: model?.entries ?? [], target: model?.targetWeightLb, unit: displayUnit)
                analyticsCard(result: result, unit: displayUnit)
                FluctuationCard(entries: model?.entries ?? [], unit: displayUnit)
                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    /// Filters entries to those within the currently selected chart range.
    ///
    /// Inputs:
    /// - entries: all entries from the model.
    ///
    /// Outputs: entries whose date is within `weightChartRange.days` of today.
    private func filteredEntries(_ entries: [WeightEntry]) -> [WeightEntry] {
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -(weightChartRange.days - 1), to: Date()
        ) ?? Date()
        return entries.filter { $0.date >= Calendar.current.startOfDay(for: cutoff) }
    }

    /// Builds the chart card showing weight points, regression dashes, and target rule.
    ///
    /// Inputs:
    /// - entries: all loaded entries (filtered/sorted internally).
    /// - target: the user's target weight in pounds, if set.
    /// - unit: current display unit.
    ///
    /// Outputs: the chart card `View`.
    private func weightOverTimeCard(entries: [WeightEntry], target: Double?, unit: WeightUnit) -> some View {
        let visible = filteredEntries(entries).sorted { $0.date < $1.date }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Weight over time")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                    .foregroundStyle(Theme.FG.secondary)
                Spacer()
                CTPSegmented(selection: $weightChartRange, options: WeightChartRange.allCases) { $0.label }
                    .frame(width: 140)
            }
            if visible.isEmpty {
                Text("Log a few weigh-ins to see your trend here.")
                    .font(.system(size: 13)).foregroundStyle(Theme.FG.tertiary)
                    .frame(height: 160)
            } else {
                let regLine = WeightTrendsModel.regressionLine(for: visible, unit: unit)
                let displayValues = visible.map { WeightFormatter.fromLb($0.weightLb, to: unit) }
                let yMin = displayValues.min() ?? 0
                let yMax = displayValues.max() ?? 0
                let pad = max(1.0, (yMax - yMin) * 0.1)
                Chart {
                    ForEach(visible) { entry in
                        let displayValue = WeightFormatter.fromLb(entry.weightLb, to: unit)
                        LineMark(x: .value("Date", entry.date),
                                 y: .value("Weight", displayValue))
                            .foregroundStyle(Theme.CTP.blue)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Date", entry.date),
                                  y: .value("Weight", displayValue))
                            .foregroundStyle(Theme.CTP.blue.opacity(0.6))
                            .symbolSize(18)
                    }
                    if let last = visible.last {
                        PointMark(x: .value("Date", last.date),
                                  y: .value("Weight", WeightFormatter.fromLb(last.weightLb, to: unit)))
                            .foregroundStyle(Theme.CTP.mauve)
                            .symbolSize(80)
                    }
                    if let reg = regLine {
                        LineMark(x: .value("Date", reg.startDate),
                                 y: .value("Trend", reg.startY),
                                 series: .value("Series", "regression"))
                            .foregroundStyle(Theme.CTP.mauve.opacity(0.9))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        LineMark(x: .value("Date", reg.endDate),
                                 y: .value("Trend", reg.endY),
                                 series: .value("Series", "regression"))
                            .foregroundStyle(Theme.CTP.mauve.opacity(0.9))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    }
                    if let target {
                        let targetDisplay = WeightFormatter.fromLb(target, to: unit)
                        if targetDisplay >= yMin - pad && targetDisplay <= yMax + pad {
                            RuleMark(y: .value("Target", targetDisplay))
                                .foregroundStyle(Theme.CTP.green)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .annotation(position: .top, alignment: .trailing) {
                                    Text("target")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Theme.CTP.green)
                                }
                        }
                    }
                }
                .chartYScale(domain: (yMin - pad)...(yMax + pad))
                .frame(height: 200)
            }
        }
        .padding(16).ctpCard()
    }

    /// Renders the maintenance/trend/ETA analytics card.
    ///
    /// Inputs:
    /// - result: precomputed analytics from the model.
    /// - unit: current display unit.
    ///
    /// Outputs: the analytics card `View`.
    private func analyticsCard(result: WeightAnalyticsResult, unit: WeightUnit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Analytics")
                .font(.system(size: 11, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(Theme.FG.secondary)
            if let m = result.maintenanceKcal {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("≈").foregroundStyle(Theme.FG.tertiary)
                    Text(m.formatted())
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.FG.primary)
                    Text("kcal/day").foregroundStyle(Theme.FG.tertiary)
                    Spacer()
                }
                Text("Maintenance").font(.system(size: 12)).foregroundStyle(Theme.FG.tertiary)
                if let avg = result.recentAvgKcal,
                   let lbPerWeek = result.trendLbPerWeek,
                   let days = result.recentWindowDays {
                    let deficitKcalDay = Int((-lbPerWeek / 7.0 * 3500.0).rounded())
                    let sign = deficitKcalDay >= 0 ? "+" : "−"
                    let rate = String(format: "%+.1f", lbPerWeek)
                    Text(
                        "Last \(days) consecutive logged days: \(avg.formatted()) avg intake"
                            + " \(sign) \(abs(deficitKcalDay)) kcal/day (\(rate) lb/wk × 3500)"
                    )
                    .font(.system(size: 11)).foregroundStyle(Theme.FG.tertiary)
                }
            } else {
                Text("Need more recent weight + calorie data for a maintenance estimate.")
                    .font(.system(size: 13)).foregroundStyle(Theme.FG.tertiary)
            }
            if let lbPerWeek = result.trendLbPerWeek {
                let sign = lbPerWeek > 0 ? "+" : ""
                Text("Trend: \(sign)\(String(format: "%.1f", lbPerWeek)) lb/week (last 28 days)")
                    .font(.system(size: 13)).foregroundStyle(Theme.FG.secondary)
            }
            etaLine(result: result, unit: unit)
        }
        .padding(16).ctpCard()
    }

    /// Renders the single ETA line under the analytics card based on result and target state.
    ///
    /// Inputs:
    /// - result: precomputed analytics from the model.
    /// - unit: current display unit.
    ///
    /// Outputs: the ETA `View`, or a prompt to set a target when none is configured.
    @ViewBuilder
    private func etaLine(result: WeightAnalyticsResult, unit: WeightUnit) -> some View {
        if model?.targetWeightLb == nil {
            Text("Set a target weight in Settings to see ETA.")
                .font(.system(size: 13)).foregroundStyle(Theme.FG.tertiary)
        } else if let eta = result.etaToTarget {
            switch eta {
            case .stable:
                Text("≈ stable, no ETA").font(.system(size: 13)).foregroundStyle(Theme.FG.secondary)
            case .never:
                Text("Trending away from target")
                    .font(.system(size: 13)).foregroundStyle(Theme.CTP.peach)
            case .date(let d):
                (Text("ETA to target: ")
                    .foregroundStyle(Theme.FG.primary)
                + Text(d.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(Theme.CTP.lavender).bold())
                    .font(.system(size: 13))
            }
        }
    }

}
