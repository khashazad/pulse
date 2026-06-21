/// FluctuationCard: Trends-screen card showing average short-term weight
/// variability. Owns window-size (2/3/4 day) and lookback (4w/3mo/1y)
/// selectors, computes `WeightFluctuation` over the passed-in entries, and
/// renders a headline average plus a Swift Charts sparkline of per-window
/// spread. Pure derivation — no networking.
import SwiftUI
import Charts

/// Selectable rolling-window size for the fluctuation card.
private enum FluctuationWindow: Int, CaseIterable, Hashable {
    case d2 = 2, d3 = 3, d4 = 4
    var label: String { "\(rawValue)d" }
}

/// Selectable lookback period for the fluctuation card.
private enum FluctuationPeriod: String, CaseIterable, Hashable {
    case w4, m3, y1
    var days: Int {
        switch self {
        case .w4: return 28
        case .m3: return 90
        case .y1: return 365
        }
    }
    var label: String {
        switch self {
        case .w4: return "4w"
        case .m3: return "3mo"
        case .y1: return "1y"
        }
    }
}

/// Card rendering average within-window weight fluctuation plus a sparkline.
struct FluctuationCard: View {
    let entries: [WeightEntry]
    let unit: WeightUnit

    @State private var window: FluctuationWindow = .d3
    @State private var period: FluctuationPeriod = .m3

    var body: some View {
        let result = WeightFluctuation.compute(
            entries: entries,
            windowDays: window.rawValue,
            periodDays: period.days,
            unit: unit
        )
        VStack(alignment: .leading, spacing: 10) {
            Text("Fluctuation")
                .font(.system(size: 11, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(Theme.FG.secondary)

            HStack(spacing: 8) {
                CTPSegmented(selection: $window, options: FluctuationWindow.allCases) { $0.label }
                CTPSegmented(selection: $period, options: FluctuationPeriod.allCases) { $0.label }
            }

            if let avg = result.average, result.sampleCount >= WeightFluctuation.minValidWindows {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(WeightFormatter.entryString(avg))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.FG.primary)
                    Text(unit.rawValue).foregroundStyle(Theme.FG.tertiary)
                    Spacer()
                }
                Text("Avg \(window.rawValue)-day swing, last \(period.label)")
                    .font(.system(size: 12)).foregroundStyle(Theme.FG.tertiary)
                sparkline(result.series)
                if let lo = result.min, let hi = result.max {
                    let range = "\(WeightFormatter.entryString(lo)) – \(WeightFormatter.entryString(hi)) \(unit.rawValue)"
                    Text("ranged \(range) · \(result.sampleCount) windows")
                        .font(.system(size: 11)).foregroundStyle(Theme.FG.tertiary)
                }
            } else {
                Text("Log more weigh-ins to see fluctuation over \(window.rawValue)-day windows.")
                    .font(.system(size: 13)).foregroundStyle(Theme.FG.tertiary)
                    .frame(height: 80, alignment: .leading)
            }
        }
        .padding(16).ctpCard()
    }

    /// Builds the per-window spread sparkline.
    /// Inputs:
    /// - points: ascending-by-date fluctuation points.
    /// Outputs: a Swift Charts line `View`.
    private func sparkline(_ points: [WeightFluctuation.Point]) -> some View {
        Chart(points) { p in
            LineMark(x: .value("Date", p.date), y: .value("Spread", p.value))
                .foregroundStyle(Theme.CTP.mauve)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 90)
    }
}
