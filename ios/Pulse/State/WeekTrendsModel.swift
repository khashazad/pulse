import Foundation

/// View model for `WeekTrendsView`: loads the week detail (`GET /activity/week`)
/// anchored to a given date and exposes a generation-guarded load state.
@Observable
final class WeekTrendsModel {
    /// Current load state for the week detail response.
    private(set) var state: LoadState<WeekDetail> = .idle
    /// The date used to anchor the week detail request.
    private let anchor: Date
    private weak var auth: AuthSession?
    /// Bumped on every `load` call; discards superseded in-flight responses.
    private var generation = 0

    /// Initializes the model with the auth session and week anchor.
    /// - Parameters:
    ///   - auth: The app's authenticated session.
    ///   - anchor: A date inside the target calendar week.
    init(auth: AuthSession, anchor: Date) {
        self.auth = auth
        self.anchor = anchor
    }

    /// Loads the week detail for `anchor` into `state`.
    /// Uses a generation counter to discard responses that were superseded
    /// by a concurrent load triggered before this one completed.
    /// - Returns: Nothing; publishes result via `state`.
    func load() async {
        guard let client = auth?.makeClient() else { state = .failed(.notSignedIn); return }
        generation += 1
        let gen = generation
        state = .loading
        do {
            let detail = try await client.activityWeek(anchor: anchor)
            guard gen == generation else { return }
            state = .loaded(detail)
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
