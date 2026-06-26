/// ActivityTypesModel: view-model for the activity-types management screen.
/// Loads the user's activity type settings and supports optimistic cardio toggling.
import Foundation
import Observation

/// Observable view-model that loads and manages the list of activity type settings.
///
/// Fetches `[ActivityTypeSetting]` from the server and exposes an optimistic
/// cardio-toggle mutation that flips the row locally, fires the API call, and
/// rolls the row back to its previous value on any error.
@Observable
final class ActivityTypesModel {
    /// The current load state for the activity types list.
    var state: LoadState<[ActivityTypeSetting]> = .idle

    private weak var auth: AuthSession?

    /// Initializes the model with the shared auth session.
    /// - Parameter auth: The app's authenticated session used to construct API clients.
    init(auth: AuthSession) {
        self.auth = auth
    }

    /// Fetches the activity types list from the server and publishes the result via `state`.
    ///
    /// Sets `state` to `.loading` before the request and to `.loaded` or `.failed`
    /// on completion. Routes a 401 response through `AuthSession`.
    /// - Returns: Nothing; result is published via `state`.
    func load() async {
        guard let client = auth?.makeClient() else { state = .failed(.notSignedIn); return }
        state = .loading
        do {
            let response = try await client.activityTypes()
            state = .loaded(response.types)
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    /// Optimistically flips `setting.isCardio` in the local list, calls the server,
    /// and rolls the row back to its prior value on any error.
    ///
    /// The flip is applied immediately to `state` so the toggle animates without waiting
    /// for the network. If the API call throws, the original `setting` value is restored.
    /// A 401 response is routed through `AuthSession`. This method is a no-op when
    /// `state` is not `.loaded`.
    /// - Parameter setting: The activity type setting whose `isCardio` flag to toggle.
    /// - Returns: Nothing; mutations are applied directly to `state`.
    func toggleCardio(_ setting: ActivityTypeSetting) async {
        guard case .loaded(let types) = state else { return }
        guard let client = auth?.makeClient() else { return }

        let flipped = ActivityTypeSetting(
            activityType: setting.activityType,
            displayName: setting.displayName,
            count: setting.count,
            isCardio: !setting.isCardio
        )

        // Optimistic update.
        state = .loaded(types.map { $0.id == setting.id ? flipped : $0 })

        do {
            let confirmed = try await client.setActivityTypeCardio(
                setting.activityType,
                isCardio: !setting.isCardio
            )
            // Apply server-confirmed value.
            if case .loaded(let current) = state {
                state = .loaded(current.map { $0.id == confirmed.id ? confirmed : $0 })
            }
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            // Roll back.
            if case .loaded(let current) = state {
                state = .loaded(current.map { $0.id == setting.id ? setting : $0 })
            }
        } catch {
            // Roll back.
            if case .loaded(let current) = state {
                state = .loaded(current.map { $0.id == setting.id ? setting : $0 })
            }
        }
    }
}
