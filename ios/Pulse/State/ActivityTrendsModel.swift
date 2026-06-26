import Foundation

/// Trends view model: loads the activity summary for a selectable period
/// and exposes display helpers for deltas.
@Observable
final class ActivityTrendsModel {
    private(set) var state: LoadState<ActivitySummary> = .idle
    private(set) var period: ActivityPeriod = .week
    private weak var auth: AuthSession?
    /// Bumped on every `load`; a load whose captured value no longer matches has been
    /// superseded by a newer period selection and must discard its result.
    private var generation = 0

    /// Initializes the model with the shared auth session.
    /// - Parameter auth: The app's authenticated session.
    init(auth: AuthSession) { self.auth = auth }

    /// Loads the summary for the current `period` into `state`, discarding the result if a
    /// newer period selection superseded this load while its request was in flight.
    /// - Returns: Nothing; result publishes via `state`.
    func load() async {
        guard let client = auth?.makeClient() else { state = .failed(.notSignedIn); return }
        generation += 1
        let gen = generation
        state = .loading
        do {
            let summary = try await client.activitySummary(period: period, anchor: nil)
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

    /// Synchronously switches the period — so the segmented control's selection (and its
    /// animation) updates immediately — then kicks off a reload. No-op when unchanged.
    /// - Parameter newPeriod: The period to display.
    /// - Returns: Nothing; updates `period` synchronously and reloads via `state`.
    func setPeriodAndLoad(_ newPeriod: ActivityPeriod) {
        guard newPeriod != period else { return }
        period = newPeriod
        Task { await load() }
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
