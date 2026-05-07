import Foundation
import Observation

@Observable
final class WeekModel {
    private(set) var state: LoadState<LogsList> = .idle
    /// User's daily macro targets, fetched alongside logs. Nil if the server
    /// has no targets for the user (404) or the request failed.
    private(set) var targets: MacroTargets?
    private weak var settings: AppSettings?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func loadLast7Days(today: Date = Date()) async {
        guard let client = settings?.makeClient() else {
            state = .failed(.notConfigured)
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
        } catch let error as DietTrackerError {
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

    static func avgProtein(_ logs: [DailyLog]) -> Double {
        let logged = logs.filter { $0.entryCount > 0 }
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalProteinG).reduce(0, +) / Double(logged.count)
    }

    static func avgCarbs(_ logs: [DailyLog]) -> Double {
        let logged = logs.filter { $0.entryCount > 0 }
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalCarbsG).reduce(0, +) / Double(logged.count)
    }

    static func avgFat(_ logs: [DailyLog]) -> Double {
        let logged = logs.filter { $0.entryCount > 0 }
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalFatG).reduce(0, +) / Double(logged.count)
    }
}
