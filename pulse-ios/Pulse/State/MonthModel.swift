/// MonthModel: view-model for the current-month macro overview.
/// Loads month-to-date logs plus targets, and exposes a static helper that
/// buckets logs into weekly averages chronologically across year boundaries.
/// Role: backing model for the Month tab/chart.
import Foundation
import Observation

/// Observable view-model that loads month-to-date logs and groups them into weekly buckets.
@Observable
final class MonthModel {
    private(set) var state: LoadState<LogsList> = .idle
    private(set) var targets: MacroTargets?
    private weak var auth: AuthSession?

    /// Initializes the month model.
    /// Inputs:
    ///   - auth: auth session used to construct an authenticated client.
    init(auth: AuthSession) {
        self.auth = auth
    }

    /// Fetches logs from the start of the current month through `today`, plus today's targets.
    /// Inputs:
    ///   - today: anchor date determining the current month (defaults to now).
    func loadCurrentMonth(today: Date = Date()) async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notSignedIn)
            return
        }
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: today) else {
            state = .failed(.server(status: -1))
            return
        }
        let from = interval.start
        let to = today
        state = .loading
        async let logsTask = client.logs(from: from, to: to)
        async let summaryTask = client.summary(date: today)
        do {
            let logs = try await logsTask
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
            let logged = bucket.filter { $0.entryCount > 0 }
            let avg = logged.isEmpty ? 0 : logged.map(\.totalCalories).reduce(0, +) / logged.count
            return PeriodBucket(
                id: "week-\(Int(key.timeIntervalSince1970))",
                label: "W\(idx + 1)",
                avgKcalPerDay: avg,
                isCurrent: key == todayWeekStart
            )
        }
    }
}
