/// Shared "which day" control for backdated logging.
/// Lets the user target Today, Yesterday, or an arbitrary past date for a log
/// action (food entry or meal log). Produces a `Date` fixed at local noon so the
/// naive wall-clock value the server reads (`consumed_at`) lands unambiguously
/// on the chosen calendar day regardless of timezone. Reused by both the
/// individual-food add flow and the saved-meal log flow.
import SwiftUI

/// Reusable backdate picker: a Today / Yesterday / Pick segmented control that
/// reveals a graphical date picker (bounded to today and earlier) when "Pick" is
/// selected. Writes the chosen day, normalized to local noon, into `date`.
struct BackdateSelector: View {
    @Binding var date: Date

    /// The three backdating modes the segmented control offers.
    private enum Mode: Hashable {
        case today, yesterday, pick
    }

    @State private var mode: Mode = .today

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Day", selection: $mode) {
                Text("Today").tag(Mode.today)
                Text("Yesterday").tag(Mode.yesterday)
                Text("Pick").tag(Mode.pick)
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, newMode in
                switch newMode {
                case .today:
                    date = Self.noon(daysAgo: 0)
                case .yesterday:
                    date = Self.noon(daysAgo: 1)
                case .pick:
                    break  // keep current date; the graphical picker drives it
                }
            }

            if mode == .pick {
                DatePicker(
                    "Pick a date",
                    selection: Binding(
                        get: { date },
                        set: { date = Self.noon(on: $0) }
                    ),
                    in: ...Date(),
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .tint(Theme.CTP.mauve)
            } else {
                Text(Self.longLabel(for: date))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.FG.tertiary)
            }
        }
    }

    /// Returns local noon for a day a given number of days before today, via
    /// the canonical `DateOnly.noon(on:)` day-anchoring rule.
    /// - Parameter daysAgo: Number of days before today (0 = today).
    /// - Returns: A `Date` at local mid-day on that day.
    private static func noon(daysAgo: Int) -> Date {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let day = cal.date(byAdding: .day, value: -daysAgo, to: startOfToday) ?? startOfToday
        return DateOnly.noon(on: day)
    }

    /// Returns local noon for the calendar day containing `someDate`, via the
    /// canonical `DateOnly.noon(on:)` day-anchoring rule.
    /// - Parameter someDate: Any instant on the target day.
    /// - Returns: A `Date` at local mid-day on that day.
    private static func noon(on someDate: Date) -> Date {
        DateOnly.noon(on: someDate)
    }

    /// Formats a friendly long-form label for the chosen day (e.g. "Fri, May 30").
    /// - Parameter date: The day to describe.
    /// - Returns: A medium-style date string in the current locale.
    private static func longLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = .current
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }
}
