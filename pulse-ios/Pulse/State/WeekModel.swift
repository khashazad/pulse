/// WeekModel: view-model for the 7-day macro overview.
/// Loads the last 7 days of logs plus today's targets, and exposes static
/// helpers that compute average daily macros across the window.
/// Role: backing model for the Week tab/chart.
import Foundation
import Observation

/// Observable view-model that loads the last seven days of logs and computes weekly averages.
@Observable
final class WeekModel {
    private(set) var state: LoadState<LogsList> = .idle
    /// User's daily macro targets, fetched alongside logs. Nil if the server
    /// has no targets for the user (404) or the request failed.
    private(set) var targets: MacroTargets?
    private weak var auth: AuthSession?

    /// Initializes the week model.
    /// Inputs:
    ///   - auth: auth session used to construct an authenticated client.
    init(auth: AuthSession) {
        self.auth = auth
    }

    /// Fetches the last 7 days of logs plus today's targets; routes 401 through AuthSession.
    /// Inputs:
    ///   - today: anchor date for the trailing 7-day window (defaults to now).
    func loadLast7Days(today: Date = Date()) async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notSignedIn)
            return
        }
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -6, to: today) ?? today
        state = .loading
        async let logsTask = client.logs(from: from, to: today)
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

    /// Average kcal per logged day (skips days with 0 entries).
    static func avgCalories(_ logs: [DailyLog]) -> Int {
        let logged = logs.filter { $0.entryCount > 0 }
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalCalories).reduce(0, +) / logged.count
    }

    /// Average protein grams per logged day (skips days with 0 entries).
    /// Inputs:
    ///   - logs: daily log rows for the window.
    /// Outputs: mean protein grams across days that had at least one entry.
    static func avgProtein(_ logs: [DailyLog]) -> Double {
        let logged = logs.filter { $0.entryCount > 0 }
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalProteinG).reduce(0, +) / Double(logged.count)
    }

    /// Average carbohydrate grams per logged day (skips days with 0 entries).
    /// Inputs:
    ///   - logs: daily log rows for the window.
    /// Outputs: mean carb grams across days that had at least one entry.
    static func avgCarbs(_ logs: [DailyLog]) -> Double {
        let logged = logs.filter { $0.entryCount > 0 }
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalCarbsG).reduce(0, +) / Double(logged.count)
    }

    /// Average fat grams per logged day (skips days with 0 entries).
    /// Inputs:
    ///   - logs: daily log rows for the window.
    /// Outputs: mean fat grams across days that had at least one entry.
    static func avgFat(_ logs: [DailyLog]) -> Double {
        let logged = logs.filter { $0.entryCount > 0 }
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalFatG).reduce(0, +) / Double(logged.count)
    }
}
