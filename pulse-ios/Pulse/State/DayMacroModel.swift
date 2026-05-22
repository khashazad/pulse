/// DayMacroModel: view-model that loads a single day's macro summary.
/// Wraps PulseClient.summary() in a LoadState and routes unauthorized
/// errors through AuthSession.
/// Role: backing model for any view that displays a one-day macro readout.
import Foundation
import Observation

/// Observable view-model wrapping the daily macro summary endpoint for a fixed date.
@Observable
final class DayMacroModel {
    let date: Date
    private(set) var state: LoadState<DailySummary> = .idle
    private weak var auth: AuthSession?

    /// Initializes the model for a specific calendar day.
    /// Inputs:
    ///   - date: the day whose summary will be fetched.
    ///   - auth: auth session used to construct an authenticated client.
    init(date: Date, auth: AuthSession) {
        self.date = date
        self.auth = auth
    }

    /// Fetches the daily summary and updates `state`; routes 401 through AuthSession.
    func load() async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notSignedIn)
            return
        }
        state = .loading
        do {
            let summary = try await client.summary(date: date)
            state = .loaded(summary)
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }
}
