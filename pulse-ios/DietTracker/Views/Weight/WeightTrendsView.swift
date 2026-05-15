import SwiftUI
import Charts

struct WeightTrendsView: View {
    @Environment(AuthSession.self) private var auth
    @State private var model: WeightTrendsModel?

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
            if model == nil { model = WeightTrendsModel(auth: auth) }
            await model?.load()
        }
        .refreshable { await model?.load() }
    }

    @ViewBuilder
    private func loadedBody(_ result: WeightAnalyticsResult) -> some View {
        let displayUnit = WeightUnit(rawValue: displayUnitRaw) ?? .lb
        ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                weightOverTimeCard(entries: model?.entries ?? [], target: model?.targetWeightLb, unit: displayUnit)
                rateVsKcalCard(result: result, unit: displayUnit)
                analyticsCard(result: result, unit: displayUnit)
                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    private func weightOverTimeCard(entries: [WeightEntry], target: Double?, unit: WeightUnit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weight over time")
                .font(.system(size: 11, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(Theme.FG.secondary)
            if entries.isEmpty {
                Text("Log a few weigh-ins to see your trend here.")
                    .font(.system(size: 13)).foregroundStyle(Theme.FG.tertiary)
                    .frame(height: 160)
            } else {
                let sorted = entries.sorted { $0.date < $1.date }
                let regLine = regressionLine(for: sorted, unit: unit)
                Chart {
                    ForEach(sorted) { entry in
                        let displayValue = WeightFormatter.fromLb(entry.weightLb, to: unit)
                        AreaMark(x: .value("Date", entry.date),
                                 y: .value("Weight", displayValue))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Theme.CTP.blue.opacity(0.25), Theme.CTP.blue.opacity(0)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", entry.date),
                                 y: .value("Weight", displayValue))
                            .foregroundStyle(Theme.CTP.blue)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                    }
                    if let last = sorted.last {
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
                        RuleMark(y: .value("Target", WeightFormatter.fromLb(target, to: unit)))
                            .foregroundStyle(Theme.CTP.green)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("target")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.CTP.green)
                            }
                    }
                }
                .frame(height: 200)
            }
        }
        .padding(16).ctpCard()
    }

    private struct RegressionLine {
        let startDate: Date
        let endDate: Date
        let startY: Double
        let endY: Double
    }

    private func regressionLine(for entries: [WeightEntry], unit: WeightUnit) -> RegressionLine? {
        let window = Array(entries.suffix(28))
        guard window.count >= 8 else { return nil }
        let ys = window.map { WeightFormatter.fromLb($0.weightLb, to: unit) }
        let n = Double(window.count)
        let xs = (0..<window.count).map(Double.init)
        let sx = xs.reduce(0, +)
        let sy = ys.reduce(0, +)
        let sxx = xs.reduce(0) { $0 + $1 * $1 }
        let sxy = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let denom = n * sxx - sx * sx
        guard denom != 0 else { return nil }
        let slope = (n * sxy - sx * sy) / denom
        let intercept = (sy - slope * sx) / n
        return RegressionLine(
            startDate: window.first!.date,
            endDate: window.last!.date,
            startY: intercept,
            endY: slope * Double(window.count - 1) + intercept
        )
    }

    private func rateVsKcalCard(result: WeightAnalyticsResult, unit: WeightUnit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rate vs calories")
                .font(.system(size: 11, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(Theme.FG.secondary)
            if result.regression == nil {
                Text("Collecting data — \(result.validWindowCount)/\(WeightAnalytics.minValidWindows) valid weeks")
                    .font(.system(size: 13)).foregroundStyle(Theme.FG.tertiary)
                    .frame(height: 160, alignment: .leading)
            } else {
                Chart {
                    ForEach(Array(result.scatter.enumerated()), id: \.offset) { _, p in
                        PointMark(x: .value("kcal", p.avgKcal),
                                  y: .value("lb/wk", p.lbPerDay * 7))
                            .foregroundStyle(Theme.CTP.lavender)
                    }
                    if let reg = result.regression, !result.scatter.isEmpty {
                        let minX = result.scatter.map(\.avgKcal).min() ?? 0
                        let maxX = result.scatter.map(\.avgKcal).max() ?? 0
                        LineMark(x: .value("kcal", minX),
                                 y: .value("lb/wk", (reg.slope * minX + reg.intercept) * 7))
                            .foregroundStyle(Theme.CTP.mauve)
                        LineMark(x: .value("kcal", maxX),
                                 y: .value("lb/wk", (reg.slope * maxX + reg.intercept) * 7))
                            .foregroundStyle(Theme.CTP.mauve)
                    }
                    if let kcal = result.maintenanceKcal {
                        RuleMark(x: .value("Maintenance", Double(kcal)))
                            .foregroundStyle(Theme.CTP.green)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    RuleMark(y: .value("Zero", 0.0))
                        .foregroundStyle(Theme.FG.tertiary.opacity(0.4))
                }
                .frame(height: 200)
            }
        }
        .padding(16).ctpCard()
    }

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
                    if let r2 = result.regression?.rSquared {
                        confidenceChip(r2: r2)
                    }
                }
                Text("Maintenance").font(.system(size: 12)).foregroundStyle(Theme.FG.tertiary)
            } else {
                Text("Need \(WeightAnalytics.minValidWindows - result.validWindowCount) more valid weeks for maintenance estimate.")
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

    private func confidenceChip(r2: Double) -> some View {
        let (label, color): (String, Color) = {
            switch r2 {
            case 0.5...: return ("R²=\(String(format: "%.2f", r2))", Theme.CTP.green)
            case 0.1..<0.5: return ("R²=\(String(format: "%.2f", r2))", Theme.CTP.peach)
            default: return ("low confidence", Theme.FG.tertiary)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}
