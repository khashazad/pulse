import Foundation
import Observation

@Observable
final class ContainersListModel {
    private(set) var state: LoadState<[Container]> = .idle
    private weak var auth: AuthSession?

    init(auth: AuthSession) {
        self.auth = auth
    }

    func load() async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notConfigured)
            return
        }
        state = .loading
        do {
            let containers = try await client.listContainers()
            state = .loaded(containers)
        } catch let error as DietTrackerError {
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

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
