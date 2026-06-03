/// Period-summary card shared by the Month and Year intake sub-tabs.
/// Shows the period's average daily kcal, a percent-of-target chip, and bucketed
/// kcal bars. Used by `MonthView` (weekly buckets) and `YearView` (monthly buckets)
/// so both render the same summary card.
import SwiftUI

/// Top summary card with a title, daily avg kcal, percent-of-target chip, and bucket bars.
struct PeriodSummaryCard: View {
    /// Card title text (e.g. "Month avg / day", "Year avg / day").
    let title: String
    /// Average daily kcal over the period.
    let avgKcal: Int
    /// Buckets for the bar chart (weekly for Month, monthly for Year).
    let buckets: [PeriodBucket]
    /// Caption for the bars sub-section (e.g. "Weekly avg", "Monthly avg").
    let barsHeader: String
    /// Daily kcal target used for the bar threshold line (nil if unset).
    let dailyTarget: Int?

    /// Percent of the daily kcal target the period average reached, or nil when
    /// there is no target or no intake. Derived from `avgKcal` and `dailyTarget`.
    private var pctOfTarget: Int? {
        guard let dailyTarget, dailyTarget > 0, avgKcal > 0 else { return nil }
        return Int((Double(avgKcal) / Double(dailyTarget) * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.FG.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(avgKcal.formatted())
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.FG.primary)
                        Text("cal")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.FG.tertiary)
                    }
                }
                Spacer()
                if let pct = pctOfTarget {
                    Text("\(pct)% of target")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(Theme.CTP.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.CTP.green.opacity(0.14)))
                }
            }

            BucketKcalBars(buckets: buckets, header: barsHeader, targetCalories: dailyTarget)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .ctpCard()
    }
}
