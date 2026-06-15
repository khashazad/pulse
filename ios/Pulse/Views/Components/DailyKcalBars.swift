/// Vertical bar chart of per-day kcal totals (used by Week view).
/// Tapping a day reveals that day's kcal + macro grams in a caption below the
/// chart; tapping the same bar again collapses it. With nothing selected the
/// most-recent day is highlighted and the caption shows a tap hint. Columns are
/// labeled with very-short weekday letters and an optional daily-target line is drawn.
import SwiftUI

/// Bar chart of `DailyLog.totalCalories` with tap-to-reveal day detail + target line.
struct DailyKcalBars: View {
    let logs: [DailyLog]
    let targetCalories: Int?

    // Store the selected day's id (its date), not the `DailyLog`, so the caption
    // always reflects fresh data after a reload and auto-deselects a vanished day.
    @State private var selectedDate: Date?

    /// Y-axis ceiling: the larger of the max day kcal and the target, floored at 1.
    /// Outputs: positive integer used as the chart's vertical scale.
    private var ceiling: Int {
        logs.calorieCeiling(target: targetCalories)
    }

    private static let cal = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Daily cal")
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
                let plotHeight = geo.size.height - 20 // weekday label below
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
                        ForEach(Array(logs.enumerated()), id: \.element.id) { idx, log in
                            barColumn(
                                log: log,
                                isLast: idx == logs.count - 1,
                                plotHeight: plotHeight
                            )
                        }
                    }
                }
            }
            .frame(height: 160)

            caption
        }
    }

    /// One bar column for a single day's log.
    /// Inputs:
    ///   - log: the day to render.
    ///   - isLast: whether this is the most-recent day (highlighted when nothing is selected).
    ///   - plotHeight: vertical space available for the bar.
    /// Outputs: composed tappable column view.
    private func barColumn(log: DailyLog, isLast: Bool, plotHeight: CGFloat) -> some View {
        let h = max(2, CGFloat(log.totalCalories) / CGFloat(ceiling) * plotHeight)
        let isSelected = selectedDate == log.id
        // The last day stays emphasized only while no explicit selection is active.
        let emphasized = isSelected || (selectedDate == nil && isLast)
        let dimmed = selectedDate != nil && !isSelected
        return VStack(spacing: 6) {
            Spacer(minLength: 0)
            StackedMacroBar(fractions: log.macroFractions)
                .frame(height: h)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.barRadius, style: .continuous))
                .barEmphasis(emphasized: emphasized, dimmed: dimmed)
            Text(Self.cal.veryShortWeekdaySymbol(for: log.date))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(emphasized ? Theme.CTP.mauve : Theme.FG.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedDate = isSelected ? nil : log.id
            }
        }
    }

    /// Below-chart readout: the selected day's kcal + macro grams, or a tap hint
    /// when nothing is selected.
    private var caption: some View {
        // Resolve the selected day from the current `logs` each render so the readout
        // follows fresh data and falls back to the hint if the day vanished.
        let day = selectedDate.flatMap { date in logs.first { $0.id == date } }
        return HStack(spacing: 10) {
            if let day {
                Text(Self.cal.shortWeekdaySymbol(for: day.date) + " · \(day.totalCalories) cal")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.FG.secondary)
                Spacer(minLength: 8)
                if day.totalProteinG + day.totalCarbsG + day.totalFatG > 0 {
                    MacroGramChips(proteinG: day.totalProteinG, carbsG: day.totalCarbsG, fatG: day.totalFatG)
                } else {
                    Text("no macros")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.FG.tertiary)
                }
            } else {
                Text("Tap a day for its macros")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.FG.tertiary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    let cal = Calendar.current
    let today = Date()
    let kcals = [2300, 2050, 1890, 2210, 2460, 1980, 1240]
    let logs: [DailyLog] = (0..<7).map { i in
        let kcal = kcals[i]
        return DailyLog(
            date: cal.date(byAdding: .day, value: -6 + i, to: today) ?? today,
            totalCalories: kcal,
            // ~30/45/25 split by calories → grams via Atwater (4/4/9).
            totalProteinG: Double(kcal) * 0.30 / 4,
            totalCarbsG: Double(kcal) * 0.45 / 4,
            totalFatG: Double(kcal) * 0.25 / 9,
            entryCount: 4
        )
    }
    return DailyKcalBars(logs: logs, targetCalories: 2200)
        .padding()
        .background(Theme.BG.primary)
        .preferredColorScheme(.dark)
}
