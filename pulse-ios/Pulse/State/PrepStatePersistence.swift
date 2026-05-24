/// Persists in-progress meal-prep calculator state (target containers, weigh-ins,
/// and the portions override) to `UserDefaults`, resolving stored container ids
/// against the live container list on load. Keeps `PrepView` free of storage details.
import Foundation

/// UserDefaults-backed store for the Prep screen's transient calculator state.
struct PrepStatePersistence {
    /// UserDefaults keys owned by the Prep screen.
    private enum Key {
        static let targets = "prep.targets"
        static let weighIns = "prep.weighIns"
        static let portionsOverride = "prep.portionsOverride"
        static let lastWeighInContainerId = "prep.lastWeighInContainerId"
    }

    /// Wire shape of a persisted target entry.
    private struct PersistedTarget: Codable {
        let containerId: String
        let count: Int
    }

    /// Wire shape of a persisted weigh-in.
    private struct PersistedWeighIn: Codable {
        let containerId: String
        let grossGrams: Double?
    }

    /// Decoded snapshot of saved state, with containers already resolved.
    struct Loaded {
        var targets: [PrepModel.TargetEntry]
        var weighIns: [PrepModel.WeighIn]
        var portionsOverride: Int?
    }

    private let defaults: UserDefaults

    /// Creates a persistence store.
    /// Inputs:
    ///   - defaults: backing store, defaulting to `.standard` (override in tests).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Loads saved state, resolving stored container ids against `list` and
    /// dropping ids no longer present.
    /// Inputs:
    ///   - list: the live containers to resolve ids against.
    /// Outputs: a `Loaded` snapshot (empty collections when nothing is saved).
    func load(matching list: [Container]) -> Loaded {
        var targets: [PrepModel.TargetEntry] = []
        var weighIns: [PrepModel.WeighIn] = []
        if let data = defaults.data(forKey: Key.targets),
           let saved = try? JSONDecoder().decode([PersistedTarget].self, from: data) {
            targets = saved.compactMap { s in
                guard let uid = UUID(uuidString: s.containerId),
                      let c = list.first(where: { $0.id == uid }) else { return nil }
                return PrepModel.TargetEntry(container: c, count: max(1, s.count))
            }
        }
        if let data = defaults.data(forKey: Key.weighIns),
           let saved = try? JSONDecoder().decode([PersistedWeighIn].self, from: data) {
            weighIns = saved.compactMap { s in
                guard let uid = UUID(uuidString: s.containerId),
                      let c = list.first(where: { $0.id == uid }) else { return nil }
                return PrepModel.WeighIn(container: c, grossGrams: s.grossGrams)
            }
        }
        let override = defaults.object(forKey: Key.portionsOverride) != nil
            ? defaults.integer(forKey: Key.portionsOverride)
            : nil
        return Loaded(targets: targets, weighIns: weighIns, portionsOverride: override)
    }

    /// Saves the calculator state.
    /// Inputs:
    ///   - targets: current target entries.
    ///   - weighIns: current weigh-ins.
    ///   - portionsOverride: current override, or nil to clear it.
    /// Outputs: nothing.
    func save(targets: [PrepModel.TargetEntry], weighIns: [PrepModel.WeighIn], portionsOverride: Int?) {
        let t = targets.map { PersistedTarget(containerId: $0.container.id.uuidString, count: $0.count) }
        let w = weighIns.map { PersistedWeighIn(containerId: $0.container.id.uuidString, grossGrams: $0.grossGrams) }
        if let td = try? JSONEncoder().encode(t) { defaults.set(td, forKey: Key.targets) }
        if let wd = try? JSONEncoder().encode(w) { defaults.set(wd, forKey: Key.weighIns) }
        if let p = portionsOverride {
            defaults.set(p, forKey: Key.portionsOverride)
        } else {
            defaults.removeObject(forKey: Key.portionsOverride)
        }
    }

    /// Stores the last-used weigh-in container id.
    /// Inputs:
    ///   - container: the container to remember.
    /// Outputs: nothing.
    func rememberLastWeighIn(_ container: Container) {
        defaults.set(container.id.uuidString, forKey: Key.lastWeighInContainerId)
    }

    /// Resolves the last-used weigh-in container from `list`, if still present.
    /// Inputs:
    ///   - list: the live containers.
    /// Outputs: the matching container, or nil when unset/deleted.
    func lastWeighInContainer(in list: [Container]) -> Container? {
        guard let raw = defaults.string(forKey: Key.lastWeighInContainerId),
              let id = UUID(uuidString: raw) else { return nil }
        return list.first(where: { $0.id == id })
    }
}
