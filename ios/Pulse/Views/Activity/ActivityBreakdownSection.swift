import SwiftUI

/// A section header for activity breakdown lists: an uppercased title on the
/// left and a monospaced item count on the right, matching the Measures
/// weight-log list style. Rendered outside the card it labels.
struct ActivitySectionHeader: View {
    /// The uppercased section title (e.g. "By month").
    let title: String
    /// Number of rows in the section, shown on the right.
    let count: Int
    /// Singular noun for the rows (pluralized with a trailing "s" when count != 1).
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.FG.secondary)
            Spacer()
            Text("\(count) \(count == 1 ? unit : unit + "s")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.FG.tertiary)
        }
        .padding(.horizontal, 4)
    }
}

/// A "By week" section: a header plus a single card listing each week as a
/// tappable `WeekRollupRow` separated by hairlines, matching the Measures list
/// style. Shared between `ActivityTrendsView` (Month period) and
/// `MonthTrendsView` so the week-list rendering has one source of truth.
struct WeekBreakdownSection: View {
    /// The weeks to list, in display order.
    let weeks: [WeekRollup]
    /// Called with the week's start date when a row is tapped.
    let onOpenWeek: (Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ActivitySectionHeader(title: "By week", count: weeks.count, unit: "week")
            VStack(spacing: 0) {
                let rows = Array(weeks.enumerated())
                ForEach(rows, id: \.element.id) { idx, week in
                    Button {
                        onOpenWeek(week.weekStart)
                    } label: {
                        WeekRollupRow(week: week)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if idx < rows.count - 1 {
                        Rectangle()
                            .fill(Theme.separator)
                            .frame(height: 0.5)
                    }
                }
            }
            .padding(.horizontal, 14)
            .ctpCard()
        }
    }
}
