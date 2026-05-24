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
    var portionsOverride: Int? = nil

    /// Total number of physical containers to fill (`Σ count`).
    var containerCount: Int { targets.reduce(0) { $0 + max(0, $1.count) } }

    /// Serving divisor: the override if present, else the container count (min 1).
    var portions: Int { portionsOverride ?? max(1, containerCount) }

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
}
