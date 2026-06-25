import Foundation

/// Trends view model: loads the activity summary for a selectable period
/// and exposes display helpers for deltas.
@Observable
final class ActivityTrendsModel {
    private(set) var state: LoadState<ActivitySummary> = .idle
    var period: ActivityPeriod = .week
    private weak var auth: AuthSession?

    /// Initializes the model with the shared auth session.
    /// - Parameter auth: The app's authenticated session.
    init(auth: AuthSession) { self.auth = auth }

    /// Loads the summary for the current `period` into `state`.
    /// - Returns: Nothing; result publishes via `state`.
    func load() async {
        guard let client = auth?.makeClient() else { state = .failed(.notSignedIn); return }
        state = .loading
        do {
            state = .loaded(try await client.activitySummary(period: period, anchor: nil))
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    /// Switches the period and reloads.
    /// - Parameter newPeriod: The period to load.
    /// - Returns: Nothing; triggers an async reload and publishes via `state`.
    func select(_ newPeriod: ActivityPeriod) async {
        guard newPeriod != period else { return }
        period = newPeriod
        await load()
    }

    /// Formats a metric delta as a short percentage string for the UI.
    /// - Parameter delta: The metric delta to format.
    /// - Returns: "+NN%" / "-NN%", or "new" when there is no prior-period baseline.
    static func deltaText(_ delta: MetricDelta) -> String {
        guard let pct = delta.pct else { return "new" }
        let pctInt = Int((pct * 100).rounded())
        return (pctInt >= 0 ? "+" : "") + "\(pctInt)%"
    }
}
