/// Vertical bar chart for bucketed average kcal/day (e.g., weekly buckets in Month,
/// monthly buckets in Year). Highlights the current bucket and draws an optional
/// target threshold line.
import SwiftUI

/// Bar chart of `PeriodBucket.avgKcalPerDay` values, with active-bucket highlight.
struct BucketKcalBars: View {
    let buckets: [PeriodBucket]
    let header: String
    let targetCalories: Int?

    /// Y-axis ceiling: the larger of max bucket value and the target, floored at 1.
    /// Outputs: positive integer used as the chart's vertical scale.
    private var ceiling: Int {
        max(buckets.map(\.avgKcalPerDay).max() ?? 0, targetCalories ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(header)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.FG.secondary)
                Spacer()
                if let target = targetCalories {
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(Theme.targetLine)
                            .frame(width: 14, height: 1)
                        Text("target \(target)")
                            .monospacedDigit()
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.FG.tertiary)
                }
            }

            GeometryReader { geo in
                let plotHeight = geo.size.height - 20
                let targetY = targetCalories.map { CGFloat($0) / CGFloat(ceiling) * plotHeight } ?? 0
                ZStack(alignment: .bottomLeading) {
                    if targetCalories != nil {
                        Rectangle()
                            .fill(Theme.targetLine.opacity(0.7))
                            .frame(height: 1)
                            .offset(y: -targetY - 20)
                            .opacity(0.7)
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(buckets) { bucket in
                            barColumn(bucket: bucket, plotHeight: plotHeight)
                        }
                    }
                }
            }
            .frame(height: 160)
        }
    }

    /// One bar column: stacked protein/carbs/fat segments with the bucket label below;
    /// the current bucket gets a highlight border + shadow.
    /// Inputs:
    ///   - bucket: the period bucket to render.
    ///   - plotHeight: vertical space available for the bar (excluding label).
    /// Outputs: composed column view.
    private func barColumn(bucket: PeriodBucket, plotHeight: CGFloat) -> some View {
        let h = max(2, CGFloat(bucket.avgKcalPerDay) / CGFloat(ceiling) * plotHeight)
        return VStack(spacing: 6) {
            Spacer(minLength: 0)
            StackedMacroBar(fractions: bucket.macroFractions)
                .frame(height: h)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.barRadius, style: .continuous))
                .barEmphasis(emphasized: bucket.isCurrent, dimmed: false)
            Text(bucket.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(bucket.isCurrent ? Theme.CTP.mauve : Theme.FG.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    let sample = MacroFractions(protein: 0.30, carbs: 0.45, fat: 0.25)
    let buckets: [PeriodBucket] = [
        .init(id: "week-1", label: "W1", avgKcalPerDay: 1980, isCurrent: false, macroFractions: sample),
        .init(id: "week-2", label: "W2", avgKcalPerDay: 2120, isCurrent: false, macroFractions: sample),
        .init(id: "week-3", label: "W3", avgKcalPerDay: 2310, isCurrent: false, macroFractions: sample),
        .init(id: "week-4", label: "W4", avgKcalPerDay: 1840, isCurrent: true, macroFractions: sample)
    ]
    return BucketKcalBars(buckets: buckets, header: "Avg cal / day", targetCalories: 2200)
        .padding()
        .background(Theme.BG.primary)
        .preferredColorScheme(.dark)
}
