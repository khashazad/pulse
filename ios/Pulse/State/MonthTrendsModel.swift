import Foundation

/// View model for `MonthTrendsView`: loads the month summary (period = .month)
/// anchored to a given date and exposes a generation-guarded load state.
/// Mirrors `ActivityTrendsModel`'s pattern but with a fixed period and anchor.
@Observable
final class MonthTrendsModel {
    /// Current load state for the month's activity summary.
    private(set) var state: LoadState<ActivitySummary> = .idle
    /// The date used to anchor the month summary request.
    private let anchor: Date
    private weak var auth: AuthSession?
    /// Bumped on every `load` call; discards superseded in-flight responses.
    private var generation = 0

    /// Initializes the model with the auth session and month anchor.
    /// - Parameters:
    ///   - auth: The app's authenticated session.
    ///   - anchor: A date inside the target calendar month.
    init(auth: AuthSession, anchor: Date) {
        self.auth = auth
        self.anchor = anchor
    }

    /// Loads the month summary for `anchor` into `state`.
    /// Uses a generation counter to discard responses that were superseded
    /// by a concurrent load triggered before this one completed.
    /// - Returns: Nothing; publishes result via `state`.
    func load() async {
        guard let client = auth?.makeClient() else { state = .failed(.notSignedIn); return }
        generation += 1
        let gen = generation
        state = .loading
        do {
            let summary = try await client.activitySummary(period: .month, anchor: anchor)
            guard gen == generation else { return }
            state = .loaded(summary)
        } catch let error as PulseError {
            guard gen == generation else { return }
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            guard gen == generation else { return }
            state = .failed(.server(status: -1))
        }
    }
}
