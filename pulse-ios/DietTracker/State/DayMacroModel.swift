import Foundation
import Observation

@Observable
final class DayMacroModel {
    let date: Date
    private(set) var state: LoadState<DailySummary> = .idle
    private weak var auth: AuthSession?

    init(date: Date, auth: AuthSession) {
        self.date = date
        self.auth = auth
    }

    func load() async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notConfigured)
            return
        }
        state = .loading
        do {
            let summary = try await client.summary(date: date)
            state = .loaded(summary)
        } catch let error as DietTrackerError {
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }
}
