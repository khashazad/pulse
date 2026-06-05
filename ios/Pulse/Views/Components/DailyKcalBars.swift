/// Vertical bar chart of per-day kcal totals (used by Week view).
/// Highlights the most-recent day, labels columns with very-short weekday letters,
/// and draws an optional daily-target threshold line.
import SwiftUI

/// Bar chart of `DailyLog.totalCalories` values with last-day highlight + target line.
struct DailyKcalBars: View {
    let logs: [DailyLog]
    let targetCalories: Int?

    /// Y-axis ceiling: the larger of the max day kcal and the target, floored at 1.
    /// Outputs: positive integer used as the chart's vertical scale.
    private var ceiling: Int {
        max(logs.map(\.totalCalories).max() ?? 0, targetCalories ?? 0, 1)
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
                            .fill(Theme.CTP.yellow)
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
                            .fill(Theme.CTP.yellow.opacity(0.7))
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
        }
    }

    /// One bar column for a single day's log.
    /// Inputs:
    ///   - log: the day to render.
    ///   - isLast: whether this is the most-recent day (triggers highlight styling).
    ///   - plotHeight: vertical space available for the bar.
    /// Outputs: composed column view.
    private func barColumn(log: DailyLog, isLast: Bool, plotHeight: CGFloat) -> some View {
        let h = max(2, CGFloat(log.totalCalories) / CGFloat(ceiling) * plotHeight)
        let gradient: LinearGradient = isLast
            ? LinearGradient(colors: [Theme.CTP.mauve, Theme.CTP.blue], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Theme.CTP.lavender.opacity(0.85), Theme.CTP.blue.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        return VStack(spacing: 6) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: Theme.Layout.barRadius, style: .continuous)
                .fill(gradient)
                .frame(height: h)
                .shadow(color: isLast ? Theme.CTP.mauve.opacity(0.45) : .clear, radius: 6)
            Text(weekdayLetter(for: log.date))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isLast ? Theme.CTP.mauve : Theme.FG.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Very-short weekday symbol (e.g. "M", "T") for the given date.
    /// Inputs:
    ///   - date: the date to format.
    /// Outputs: one-letter weekday string from the current calendar.
    private func weekdayLetter(for date: Date) -> String {
        let symbols = Self.cal.veryShortWeekdaySymbols
        let comp = Self.cal.component(.weekday, from: date)
        return symbols[(comp - 1) % symbols.count]
    }
}

#Preview {
    let cal = Calendar.current
    let today = Date()
    let kcals = [2300, 2050, 1890, 2210, 2460, 1980, 1240]
    let logs: [DailyLog] = (0..<7).map { i in
        DailyLog(
            date: cal.date(byAdding: .day, value: -6 + i, to: today) ?? today,
            totalCalories: kcals[i],
            totalProteinG: 0, totalCarbsG: 0, totalFatG: 0,
            entryCount: 4
        )
    }
    return DailyKcalBars(logs: logs, targetCalories: 2200)
        .padding()
        .background(Theme.BG.primary)
        .preferredColorScheme(.dark)
}
