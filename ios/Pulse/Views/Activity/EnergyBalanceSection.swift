import SwiftUI

/// One row in the energy-balance card, rendering a bucket's three energy inputs
/// (dietary intake, cardio burn, weight delta) and the derived maintenance estimate.
private struct EnergyBalanceBucketRow: View {
    /// The bucket to render.
    let bucket: EnergyBalanceBucket

    /// Formatted average intake string, or "—" when nil.
    /// - Returns: E.g. "2100 kcal/day" or "—".
    private var intakeText: String {
        guard let intake = bucket.intakeCalPerDay else { return "—" }
        return "\(Int(intake.rounded())) kcal/day"
    }

    /// Formatted total cardio-burn string.
    /// - Returns: E.g. "1200 kcal".
    private var cardioText: String {
        "\(Int(bucket.cardioCalTotal.rounded())) kcal"
    }

    /// Signed weight-delta string with one decimal place, or "—" when nil.
    /// Uses Unicode minus (−) for negative values to distinguish from a hyphen.
    /// - Returns: E.g. "−1.2 lb", "+0.5 lb", or "—".
    private var weightDeltaText: String {
        guard let delta = bucket.weightDeltaLb else { return "—" }
        let sign = delta >= 0 ? "+" : "\u{2212}"
        return "\(sign)\(String(format: "%.1f", abs(delta))) lb"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bucket.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.FG.primary)
            HStack(spacing: 0) {
                inputColumn("Intake", value: intakeText)
                inputColumn("Cardio", value: cardioText)
                inputColumn("Weight \u{0394}", value: weightDeltaText)
            }
            maintenanceLine
        }
    }

    /// Secondary maintenance-estimate line, or a placeholder when the estimate
    /// is unavailable.
    /// - Returns: A `Text` view styled as tertiary secondary information.
    @ViewBuilder
    private var maintenanceLine: some View {
        if let maint = bucket.estMaintenancePerDay {
            Text("≈ \(Int(maint.rounded())) kcal/day maint. (est)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.FG.tertiary)
        } else {
            Text("— maint. (est)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.FG.tertiary)
        }
    }

    /// A labelled value column for one energy-balance input metric.
    /// - Parameters:
    ///   - label: The metric label shown above the value (e.g. "Intake").
    ///   - value: The formatted value string (e.g. "2100 kcal/day").
    /// - Returns: A vertically-stacked label+value column expanded to one-third
    ///   of the available row width.
    private func inputColumn(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.FG.tertiary)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.FG.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A card titled "Energy balance" listing one row per bucket with the three
/// energy inputs (dietary intake, cardio output, weight change) and the derived
/// maintenance estimate.  Shown only when the bucket array is non-empty.
struct EnergyBalanceSection: View {
    /// The energy-balance buckets to render, ordered earliest-first.
    let buckets: [EnergyBalanceBucket]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            activityCardTitle("Energy balance")
            VStack(spacing: 12) {
                ForEach(buckets) { bucket in
                    EnergyBalanceBucketRow(bucket: bucket)
                }
            }
        }
        .padding(16)
        .ctpCard()
    }
}
