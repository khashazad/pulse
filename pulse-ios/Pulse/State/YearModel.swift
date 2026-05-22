/// YearModel: view-model for the current-year macro overview.
/// Loads year-to-date logs plus targets, and exposes a static helper that
/// buckets logs into monthly averages.
/// Role: backing model for the Year tab/chart.
import Foundation
import Observation

/// Observable view-model that loads year-to-date logs and groups them into monthly buckets.
@Observable
final class YearModel {
    private(set) var state: LoadState<LogsList> = .idle
    private(set) var targets: MacroTargets?
    private weak var auth: AuthSession?

    /// Initializes the year model.
    /// Inputs:
    ///   - auth: auth session used to construct an authenticated client.
    init(auth: AuthSession) {
        self.auth = auth
    }

    /// Fetches logs from the start of the current year through `today`, plus today's targets.
    /// Inputs:
    ///   - today: anchor date determining the current year (defaults to now).
    func loadCurrentYear(today: Date = Date()) async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notSignedIn)
            return
        }
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .year, for: today) else {
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
            let logged = bucket.filter { $0.entryCount > 0 }
            let avg = logged.isEmpty ? 0 : logged.map(\.totalCalories).reduce(0, +) / logged.count
            let label = (1...12).contains(monthKey) ? symbols[monthKey - 1] : "?"
            return PeriodBucket(
                id: "month-\(monthKey)",
                label: label,
                avgKcalPerDay: avg,
                isCurrent: monthKey == currentMonth
            )
        }
    }
}
