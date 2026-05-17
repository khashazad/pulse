/// ContainersListModel: view-model for the containers (tare-weight presets) list.
/// Loads, exposes, and deletes containers via DietTrackerClient.
/// Role: backing model for the Containers list screen.
import Foundation
import Observation

/// Observable view-model that loads and mutates the user's container presets.
@Observable
final class ContainersListModel {
    private(set) var state: LoadState<[Container]> = .idle
    private weak var auth: AuthSession?

    /// Initializes the containers list model.
    /// Inputs:
    ///   - auth: auth session used to construct an authenticated client.
    init(auth: AuthSession) {
        self.auth = auth
    }

    /// Fetches the containers list; routes 401 through AuthSession.
    func load() async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notSignedIn)
            return
        }
        state = .loading
        do {
            let containers = try await client.listContainers()
            state = .loaded(containers)
        } catch let error as DietTrackerError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    /// Deletes a container by id and reloads the list to reconcile state.
    /// Inputs:
    ///   - id: identifier of the container to delete.
    func delete(id: UUID) async {
        guard let client = auth?.makeClient() else { return }
        do {
            try await client.deleteContainer(id: id)
        } catch {
            // Best-effort: fall through to reload to surface the real state.
        }
        await load()
    }
}
