import Foundation
import Observation

@Observable
final class UserTargetsStore {
    private(set) var targets: MacroTargets?

    func update(_ targets: MacroTargets) {
        self.targets = targets
    }

    func clear() {
        self.targets = nil
    }

    func refresh(client: DietTrackerClient) async {
        if let t = try? await client.fetchTargets() {
            self.targets = t
        }
    }
}
