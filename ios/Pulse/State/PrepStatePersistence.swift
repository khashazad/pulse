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
        static let batchItems = "prep.batchItems"
        /// Batch-agnostic BY DESIGN: one global set for the single in-flight
        /// prep batch (cleared when the batch empties). If multiple/named
        /// batches are ever introduced this must become batch-keyed, or
        /// applied-day warnings will cross-contaminate between batches.
        static let appliedDates = "prep.appliedDates"
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

    /// Loads the persisted batch food items.
    /// Outputs: the saved items, or an empty array when nothing is stored or decoding fails.
    func loadBatchItems() -> [BatchFoodItem] {
        guard let data = defaults.data(forKey: Key.batchItems),
              let items = try? JSONDecoder().decode([BatchFoodItem].self, from: data) else { return [] }
        return items
    }

    /// Saves the batch food items, replacing any previously stored list.
    /// Inputs:
    ///   - items: the current batch items to persist.
    func saveBatchItems(_ items: [BatchFoodItem]) {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Key.batchItems)
        }
    }

    /// Loads the set of day keys (`yyyy-MM-dd`) this batch has been applied to.
    /// Outputs: the saved day keys, or an empty set when nothing is stored.
    func loadAppliedDates() -> Set<String> {
        Set(defaults.stringArray(forKey: Key.appliedDates) ?? [])
    }

    /// Saves the set of day keys this batch has been applied to, replacing any
    /// previously stored set.
    /// Inputs:
    ///   - dates: the day keys (`yyyy-MM-dd`) to persist.
    /// Outputs: nothing.
    func saveAppliedDates(_ dates: Set<String>) {
        defaults.set(Array(dates).sorted(), forKey: Key.appliedDates)
    }
}
