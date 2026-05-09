import Foundation
import Observation

@Observable
final class MonthModel {
    private(set) var state: LoadState<LogsList> = .idle
    private(set) var targets: MacroTargets?
    private weak var auth: AuthSession?

    init(auth: AuthSession) {
        self.auth = auth
    }

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
        } catch let error as DietTrackerError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    /// Group logs into weekly buckets within the displayed month.
    /// Buckets are keyed by the week's start date (not weekOfYear) so the order
    /// stays chronological across year boundaries (e.g., Dec week 52 → Jan week 1).
    static func weeklyBuckets(_ logs: [DailyLog], today: Date = Date(), calendar: Calendar = .current) -> [PeriodBucket] {
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
