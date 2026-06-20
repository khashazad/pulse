/// PrepModel: calculator for the multi-container meal-prep screen.
/// Holds the target containers to divide a batch into and the weigh-ins used to
/// measure the batch's net food, then derives total net, even per-container fill
/// targets, and a decoupled per-portion serving size.
/// Role: backing view-model for the Prep screen.
import Foundation
import Observation

/// Observable view-model computing net, per-container, and per-portion weights.
@Observable
final class PrepModel {
    /// A target container the batch is divided into, with how many of it to fill.
    /// Storing the whole `Container` (vs. an id + tare) keeps tare drift impossible;
    /// `reconcile(with:)` refreshes the snapshot when the source list reloads.
    struct TargetEntry: Identifiable, Equatable {
        let id: UUID
        var container: Container
        var count: Int

        /// Creates a target entry.
        /// Inputs:
        ///   - id: stable identity, defaulting to a fresh UUID.
        ///   - container: the container to fill.
        ///   - count: how many of this container, defaulting to 1.
        /// Outputs: a `TargetEntry`.
        init(id: UUID = UUID(), container: Container, count: Int = 1) {
            self.id = id
            self.container = container
            self.count = count
        }
    }

    /// A single scale reading taken while weighing the batch in chunks. The
    /// container supplies the tare to subtract from `grossGrams`.
    struct WeighIn: Identifiable, Equatable {
        let id: UUID
        var container: Container
        var grossGrams: Double?

        /// Creates a weigh-in.
        /// Inputs:
        ///   - id: stable identity, defaulting to a fresh UUID.
        ///   - container: the container on the scale (for its tare).
        ///   - grossGrams: the gross reading, nil until entered.
        /// Outputs: a `WeighIn`.
        init(id: UUID = UUID(), container: Container, grossGrams: Double? = nil) {
            self.id = id
            self.container = container
            self.grossGrams = grossGrams
        }
    }

    var targets: [TargetEntry] = []
    var weighIns: [WeighIn] = []
    /// When nil, `portions` follows `containerCount`; once set, the two decouple.
    var portionsOverride: Int?

    /// UserDefaults-backed persistence for the calculator state. Owned by the model
    /// so `PrepView` stays a renderer and delegates load/save/reconcile here.
    private let store: PrepStatePersistence
    /// Whether saved state has already been hydrated from `store`. Stays false
    /// until a successful hydration so a failed initial container load can still
    /// hydrate on a later reload.
    private var hydrated = false

    /// Creates a prep calculator model.
    /// Inputs:
    ///   - store: persistence backing the calculator state (defaults to `.init()`).
    /// Outputs: a `PrepModel`.
    init(store: PrepStatePersistence = PrepStatePersistence()) {
        self.store = store
    }

    /// Total number of physical containers to fill (`Σ count`).
    var containerCount: Int { targets.reduce(0) { $0 + max(0, $1.count) } }

    /// Serving divisor: the override if present, else the container count (min 1).
    var portions: Int { portionsOverride ?? max(1, containerCount) }

    /// True when the calculator carries user input (targets, weigh-ins, or a
    /// portions override). Batch-food emptiness is composed by the view, which
    /// also owns the batch model.
    var isDirty: Bool {
        !targets.isEmpty || !weighIns.isEmpty || portionsOverride != nil
    }

    /// Net food across all weigh-ins (`Σ max(0, gross - tare)`); nil until a gross
    /// is entered so the result rows stay blank.
    var totalNetGrams: Double? {
        let nets = weighIns.compactMap { w in
            w.grossGrams.map { max(0, $0 - w.container.tareWeightG) }
        }
        return nets.isEmpty ? nil : nets.reduce(0, +)
    }

    /// True when at least one weigh-in still has no gross reading, so the
    /// computed total reflects only a partially-measured batch.
    var hasUnenteredWeighIns: Bool {
        weighIns.contains { $0.grossGrams == nil }
    }

    /// Serving size: total net divided by `portions` (min 1).
    var perPortionGrams: Double? {
        totalNetGrams.map { $0 / Double(max(1, portions)) }
    }

    /// Net food per physical container (even split); nil with no targets.
    var perContainerNetGrams: Double? {
        guard let net = totalNetGrams, containerCount > 0 else { return nil }
        return net / Double(containerCount)
    }

    /// Scale reading to fill the given target to (its net share + its tare).
    /// Inputs:
    ///   - entry: the target whose fill reading is wanted.
    /// Outputs: the target gross grams, or nil when net/targets are unavailable.
    func targetGross(for entry: TargetEntry) -> Double? {
        perContainerNetGrams.map { $0 + entry.container.tareWeightG }
    }

    /// True when every target shares one tare, so the fill reading collapses to
    /// a single number (otherwise the UI shows a per-entry breakdown).
    var targetTaresAreUniform: Bool {
        Set(targets.map { $0.container.tareWeightG }).count <= 1
    }

    /// Refreshes each target/weigh-in container snapshot from the freshly loaded
    /// list and drops entries whose container was deleted — keeping tare from
    /// drifting after edits/deletes in the container manager.
    /// Inputs:
    ///   - list: the latest containers loaded from the server.
    /// Outputs: nothing; mutates `targets` and `weighIns` in place.
    func reconcile(with list: [Container]) {
        targets = targets.compactMap { entry in
            guard let fresh = list.first(where: { $0.id == entry.container.id }) else { return nil }
            var e = entry
            e.container = fresh
            return e
        }
        weighIns = weighIns.compactMap { w in
            guard let fresh = list.first(where: { $0.id == w.container.id }) else { return nil }
            var nw = w
            nw.container = fresh
            return nw
        }
    }

    // MARK: - Persistence lifecycle

    /// Loads saved targets/weigh-ins/portions from persistence once, matching stored
    /// container ids against `list` (dropping unknown ids). Stays pending (does not
    /// mark itself done) until a successful load, so a failed initial container load
    /// can still hydrate on a later reload.
    /// Inputs:
    ///   - list: the live containers to resolve ids against, or nil when the
    ///     container list has not loaded yet (in which case this is a no-op).
    /// Outputs: the persisted batch food items when hydration occurred, or nil when
    ///   the call was skipped (list unavailable or already hydrated) so the caller
    ///   only reseeds its batch state on an actual hydration.
    func hydrateIfNeeded(matching list: [Container]?) -> [BatchFoodItem]? {
        guard !hydrated else { return nil }
        guard let list else { return nil }
        hydrated = true
        let loaded = store.load(matching: list)
        targets = loaded.targets
        weighIns = loaded.weighIns
        portionsOverride = loaded.portionsOverride
        return store.loadBatchItems()
    }

    /// Writes the current targets/weigh-ins/portions to persistence.
    /// Outputs: nothing.
    func persist() {
        store.save(targets: targets, weighIns: weighIns, portionsOverride: portionsOverride)
    }

    /// Wipes the page to a clean slate for a brand-new batch: clears targets,
    /// weigh-ins, and the portions override, persists the empty calculator state,
    /// and empties the batch foods — which also clears the applied-days memory
    /// (see `saveBatchItems`, where empty is the batch-identity boundary).
    /// Outputs: nothing; mutates and persists model state.
    func resetAll() {
        targets = []
        weighIns = []
        portionsOverride = nil
        persist()
        saveBatchItems([])
    }

    /// Refreshes container snapshots and drops deleted ones using `list`, but only
    /// when a loaded list is available.
    /// Inputs:
    ///   - list: the live containers, or nil when the list has not loaded yet.
    /// Outputs: nothing.
    func reconcileIfLoaded(_ list: [Container]?) {
        guard let list else { return }
        reconcile(with: list)
    }

    /// Loads the persisted batch food items.
    /// Outputs: the saved items, or an empty array when nothing is stored.
    func loadBatchItems() -> [BatchFoodItem] {
        store.loadBatchItems()
    }

    /// Saves the batch food items, replacing any previously stored list. Emptying
    /// the batch also clears the applied-dates memory, because a new batch is a
    /// new identity for the duplicate-apply warning. NOTE: "empty" is the only
    /// identity boundary — load-bearing assumption. Swapping items one-by-one
    /// without ever hitting zero keeps the old applied-dates (a warn-only,
    /// bounded staleness accepted in the design over explicit batch ids).
    /// Inputs:
    ///   - items: the current batch items to persist.
    /// Outputs: nothing.
    func saveBatchItems(_ items: [BatchFoodItem]) {
        store.saveBatchItems(items)
        if items.isEmpty { store.saveAppliedDates([]) }
    }

    /// Loads the day keys (`yyyy-MM-dd`) this batch has already been applied to.
    /// Outputs: the saved day keys, empty when none.
    func loadAppliedDates() -> Set<String> {
        store.loadAppliedDates()
    }

    /// Records additional applied day keys, unioning with what is stored so
    /// repeat applies accumulate rather than overwrite.
    /// Inputs:
    ///   - newDates: day keys that were just successfully applied.
    /// Outputs: nothing.
    func recordAppliedDates(_ newDates: Set<String>) {
        store.saveAppliedDates(store.loadAppliedDates().union(newDates))
    }
}
