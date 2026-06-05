/// UserTargetsStore: app-wide cache of the user's macro targets.
/// Holds the most-recent MacroTargets and exposes update/clear/refresh/save
/// methods so any view-model can read, refresh, or persist targets without
/// duplicating the call.
/// Role: shared observable injected into views/models that need target values.
import Foundation
import Observation

/// Observable store that caches the current user's macro targets for shared access across the app.
@Observable
final class UserTargetsStore {
    private(set) var targets: MacroTargets?

    /// Replaces the cached targets with the provided value.
    /// Inputs:
    ///   - targets: new MacroTargets to publish to observers.
    func update(_ targets: MacroTargets) {
        self.targets = targets
    }

    /// Clears the cached targets (e.g. on sign-out).
    func clear() {
        self.targets = nil
    }

    /// Fetches the latest targets from the server and updates the cache on success;
    /// silently no-ops on failure.
    /// Inputs:
    ///   - client: authenticated client used to call fetchTargets().
    func refresh(client: PulseClient) async {
        if let t = try? await client.fetchTargets() {
            self.targets = t
        }
    }

    /// Persists the full target profile with a single PUT /targets and
    /// publishes the server-echoed value to the cache on success.
    /// Inputs:
    ///   - targets: complete desired macro targets (+ optional weight goal).
    ///   - client: authenticated client used for the upsert.
    /// Outputs: the server-echoed `MacroTargets` that was cached.
    /// Throws: `PulseError` when the upsert fails; the cache is left untouched.
    @discardableResult
    func save(_ targets: MacroTargets, client: PulseClient) async throws -> MacroTargets {
        let persisted = try await client.upsertTargets(targets)
        update(persisted)
        return persisted
    }

}
