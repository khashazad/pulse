import SwiftUI

/// A single week-breakdown row: week-start label, session count, total duration,
/// and a secondary per-type frequency sub-line (e.g. "Weights 3 · Running 2").
/// Shared between `ActivityTrendsView` (Month period) and `MonthTrendsView` so
/// the row rendering has one source of truth.
struct WeekRollupRow: View {
    /// The week rollup data to render.
    let week: WeekRollup

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Week of \(week.weekStart.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.FG.primary)
                Spacer()
                Text(
                    "\(week.sessionCount) · "
                    + week.durationMin.asDurationFromMinutes
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.FG.tertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.FG.tertiary)
            }
            if !week.byType.isEmpty {
                Text(
                    week.byType.map {
                        "\(ActivityType.displayName($0.activityType)) \($0.count)"
                    }.joined(separator: " · ")
                )
                .font(.system(size: 11))
                .foregroundStyle(Theme.FG.tertiary)
            }
        }
    }
}
