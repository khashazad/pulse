/// PeriodIntakeModel: unified view-model for the week/month/year macro overviews.
/// Loads the logs for a date window determined by its `range`, plus today's
/// targets, and exposes static bucketing helpers for the month (weekly buckets)
/// and year (monthly buckets) charts. Replaces the structurally-identical
/// `WeekModel` / `MonthModel` / `YearModel`.
import Foundation
import Observation

/// Observable view-model that loads a period's daily logs (+ today's targets) and,
/// for month/year, buckets them for the period summary chart.
@Observable
final class PeriodIntakeModel {
    /// The period the model summarizes; selects the date window and bucket granularity.
    enum Range {
        case week
        case month
        case year
    }

    /// Which period this model summarizes.
    let range: Range
    private(set) var state: LoadState<LogsList> = .idle
    /// User's daily macro targets, fetched alongside logs. Nil if the server
    /// has no targets for the user (404) or the request failed.
    private(set) var targets: MacroTargets?
    private weak var auth: AuthSession?

    /// Initializes the period model.
    /// Inputs:
    ///   - range: the period (week/month/year) this model summarizes.
    ///   - auth: auth session used to construct an authenticated client.
    init(range: Range, auth: AuthSession) {
        self.range = range
        self.auth = auth
    }

    /// Fetches the logs for the period's date window plus today's targets, in
    /// parallel; routes 401 through `AuthSession`. The window is derived from
    /// `range`: the trailing 7 days for `.week`, the current calendar month for
    /// `.month`, and the current calendar year for `.year`.
    /// Inputs:
    ///   - today: anchor date for the window (defaults to now).
    /// Outputs: nothing; updates `state` and `targets`.
    func load(today: Date = Date()) async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notSignedIn)
            return
        }
        let cal = Calendar.current
        let from: Date
        switch range {
        case .week:
            from = cal.date(byAdding: .day, value: -6, to: today) ?? today
        case .month:
            guard let interval = cal.dateInterval(of: .month, for: today) else {
                state = .failed(.server(status: -1))
                return
            }
            from = interval.start
        case .year:
            guard let interval = cal.dateInterval(of: .year, for: today) else {
                state = .failed(.server(status: -1))
                return
            }
            from = interval.start
        }
        let to = today
        state = .loading
        async let logsTask = client.logs(from: from, to: to)
        async let summaryTask = client.summary(date: today)
        do {
            let logs = try await logsTask
            // Targets are best-effort; missing targets shouldn't block the chart.
            self.targets = (try? await summaryTask)?.target
            state = .loaded(logs)
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    /// Group logs into weekly buckets within the displayed month.
    /// Buckets are keyed by the week's start date (not weekOfYear) so the order
    /// stays chronological across year boundaries (e.g., Dec week 52 → Jan week 1).
    /// Inputs:
    ///   - logs: daily log rows for the displayed month.
    ///   - today: date used to mark the "current" bucket.
    ///   - calendar: calendar used to derive week boundaries.
    /// Outputs: ordered weekly buckets with average kcal per logged day.
    static func weeklyBuckets(_ logs: [DailyLog], today: Date = Date(), calendar: Calendar = .current) -> [PeriodBucket] {
        /// Returns the start-of-week for the given date, falling back to the date itself.
        /// Inputs:
        ///   - date: date whose week-start is needed.
        /// Outputs: the first instant of the week containing `date`.
        func weekStart(for date: Date) -> Date {
            calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        }
        let groups = Dictionary(grouping: logs) { weekStart(for: $0.date) }
        let todayWeekStart = weekStart(for: today)
        return groups.keys.sorted().enumerated().map { idx, key in
            let bucket = groups[key] ?? []
            return PeriodBucket(
                id: "week-\(Int(key.timeIntervalSince1970))",
                label: "W\(idx + 1)",
                avgKcalPerDay: bucket.avgCalories,
                isCurrent: key == todayWeekStart
            )
        }
    }

    /// Group logs into monthly buckets within the current year.
    /// Each bucket's value is the average kcal across days that have entries.
    /// Inputs:
    ///   - logs: daily log rows for the displayed year.
    ///   - today: date used to mark the "current" bucket.
    ///   - calendar: calendar used to derive month components.
    /// Outputs: ordered monthly buckets with average kcal per logged day.
    static func monthlyBuckets(_ logs: [DailyLog], today: Date = Date(), calendar: Calendar = .current) -> [PeriodBucket] {
        let groups = Dictionary(grouping: logs) { calendar.component(.month, from: $0.date) }
        let symbols = calendar.shortMonthSymbols
        let currentMonth = calendar.component(.month, from: today)
        return groups.keys.sorted().map { monthKey in
            let bucket = groups[monthKey] ?? []
            let label = (1...12).contains(monthKey) ? symbols[monthKey - 1] : "?"
            return PeriodBucket(
                id: "month-\(monthKey)",
                label: label,
                avgKcalPerDay: bucket.avgCalories,
                isCurrent: monthKey == currentMonth
            )
        }
    }
}
