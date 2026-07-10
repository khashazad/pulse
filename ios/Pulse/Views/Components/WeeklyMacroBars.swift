/// One week's row in the Month view: a stacked protein/carbs/fat bar per logged
/// day, scaled to a shared month-wide ceiling, with a solid daily-target line and
/// a thin dashed week-average line. Tapping a bar reveals that day's exact macro
/// percentages; with nothing selected the caption shows the week's average split.
import SwiftUI

/// Per-week stacked-macro bar chart with target + average reference lines.
struct WeeklyMacroBars: View {
    let group: PeriodIntakeModel.WeekLogGroup
    /// Shared y-axis ceiling (max day kcal or target across the whole month) so all
    /// week rows use one vertical scale and the target line sits at a constant height.
    let ceiling: Int
    let targetCalories: Int?

    // Store the selected day's id (its date), not the `DailyLog` value, so the caption
    // always reflects fresh data after a reload and auto-deselects a day that vanishes.
    @State private var selectedDate: Date?

    private static let cal = Calendar.current
    private var safeCeiling: CGFloat { CGFloat(max(ceiling, 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            chart
            caption
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .ctpCard()
    }

    // MARK: - Header

    /// Week title + average kcal/day on the left, line legend on the right.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(group.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.FG.primary)
                    if group.isCurrent {
                        Text("now")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.5)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.CTP.mauve)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.CTP.mauve.opacity(0.16)))
                    }
                }
                Text("avg \(group.avgKcal) cal/day")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.FG.secondary)
            }
            Spacer()
            lineLegend
        }
    }

    /// Legend describing the dashed average line and solid target line.
    private var lineLegend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                DashedLineSwatch()
                    .foregroundStyle(Theme.CTP.teal.opacity(0.85))
                    .frame(width: 14, height: 2)
                Text("avg")
            }
            if targetCalories != nil {
                HStack(spacing: 5) {
                    Rectangle().fill(Theme.targetLine).frame(width: 14, height: 1.5)
                    Text("target")
                }
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.FG.tertiary)
    }

    // MARK: - Chart

    private var chart: some View {
        GeometryReader { geo in
            let labelSpace: CGFloat = 20
            let plotHeight = geo.size.height - labelSpace
            let avgKcal = group.avgKcal
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(group.days) { day in
                        barColumn(day: day, plotHeight: plotHeight)
                    }
                }
                // Reference lines are drawn after the bars so the target and
                // week-average lines read on top of them rather than being
                // hidden behind taller bars.
                if let target = targetCalories, target > 0 {
                    Rectangle()
                        .fill(Theme.targetLine.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .frame(height: 1.5)
                        .offset(y: referenceOffset(value: target, plotHeight: plotHeight, labelSpace: labelSpace))
                }
                if avgKcal > 0 {
                    DashedLineSwatch()
                        .foregroundStyle(Theme.CTP.teal.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: 2)
                        .offset(y: referenceOffset(value: avgKcal, plotHeight: plotHeight, labelSpace: labelSpace))
                }
            }
        }
        .frame(height: 150)
    }

    /// Vertical offset (from the chart's bottom anchor) that places a reference line at
    /// `value` on the shared ceiling scale, lifted above the reserved weekday-label row.
    /// Inputs:
    ///   - value: kcal value the line marks.
    ///   - plotHeight: vertical space available for bars (excludes the label row).
    ///   - labelSpace: reserved height for the weekday labels below the bars.
    /// Outputs: a negative offset (upward) matching the bar-top height for `value`.
    private func referenceOffset(value: Int, plotHeight: CGFloat, labelSpace: CGFloat) -> CGFloat {
        -(CGFloat(value) / safeCeiling * plotHeight) - labelSpace
    }

    /// One day's stacked-macro bar plus its weekday letter.
    /// Inputs:
    ///   - day: the day's log to render.
    ///   - plotHeight: vertical space available for the bar.
    /// Outputs: a tappable column view.
    private func barColumn(day: DailyLog, plotHeight: CGFloat) -> some View {
        let barHeight = max(2, CGFloat(day.totalCalories) / safeCeiling * plotHeight)
        let isSelected = selectedDate == day.id
        // Excluded days always read dimmed (they don't count toward the week
        // average), as do non-selected bars while another is selected.
        let dimmed = day.excluded || (selectedDate != nil && !isSelected)
        return VStack(spacing: 6) {
            Spacer(minLength: 0)
            StackedMacroBar(fractions: day.macroFractions)
                .frame(height: barHeight)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.barRadius, style: .continuous))
                .barEmphasis(emphasized: isSelected, dimmed: dimmed)
            Text(Self.cal.veryShortWeekdaySymbol(for: day.date))
                .font(.system(size: 11, weight: .semibold))
                .strikethrough(day.excluded, color: Theme.FG.tertiary)
                .foregroundStyle(isSelected ? Theme.CTP.mauve : Theme.FG.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedDate = isSelected ? nil : day.id
            }
        }
    }

    // MARK: - Caption

    /// Below-chart readout: the selected day's macro grams, or the week-average
    /// grams when nothing is selected.
    private var caption: some View {
        // Resolve the selected day from the current `group.days` each render so the
        // readout follows fresh data and falls back to the week average if it vanished.
        let day = selectedDate.flatMap { date in group.days.first { $0.id == date } }
        let title = day.map {
            Self.cal.shortWeekdaySymbol(for: $0.date) + " · \($0.totalCalories) cal"
                + ($0.excluded ? " · excluded" : "")
        } ?? "Week avg"
        let grams = selectedGrams(day: day)
        return HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.FG.secondary)
            Spacer(minLength: 8)
            if let grams {
                MacroGramChips(proteinG: grams.protein, carbsG: grams.carbs, fatG: grams.fat)
            } else {
                Text("no macros")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.FG.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Macro grams to show in the caption: the selected day's totals, or the
    /// week's per-logged-day averages when nothing is selected.
    /// Inputs:
    ///   - day: the currently selected day's log, or nil when none is selected.
    /// Outputs: a (protein, carbs, fat) gram tuple, or nil when there are no macros.
    private func selectedGrams(day: DailyLog?) -> (protein: Double, carbs: Double, fat: Double)? {
        if let day {
            guard day.totalProteinG + day.totalCarbsG + day.totalFatG > 0 else { return nil }
            return (day.totalProteinG, day.totalCarbsG, day.totalFatG)
        }
        let avg = (group.days.avgProtein, group.days.avgCarbs, group.days.avgFat)
        guard avg.0 + avg.1 + avg.2 > 0 else { return nil }
        return (avg.0, avg.1, avg.2)
    }

}

/// Reusable dashed horizontal line (1pt) drawn with the current foreground style.
struct DashedLineSwatch: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
            }
            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
        }
    }
}
