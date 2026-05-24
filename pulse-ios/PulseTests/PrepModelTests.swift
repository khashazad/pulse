/// Unit tests for `PrepModel`, the calculator behind the multi-container meal-prep screen.
/// Verifies container-count math (list + multiplier), the decoupled portions divisor,
/// summed weigh-in net with per-row negative clamping, even per-container split, target
/// scale readings (uniform + mixed tare), nil propagation, and container reconcile.
/// Part of the iOS app's view-model test suite.
import XCTest
@testable import Pulse

final class PrepModelTests: XCTestCase {

    /// Builds a `Container` fixture with the requested tare weight and id.
    /// Inputs:
    ///   - tare: tare weight in grams.
    ///   - name: display name, defaulting to "X".
    ///   - id: container id, defaulting to a fresh UUID.
    /// Outputs: a fully formed `Container` for model setup.
    private func mkContainer(tare: Double, name: String = "X", id: UUID = UUID()) -> Container {
        Container(
            id: id,
            userKey: "khash",
            name: name,
            normalizedName: name.lowercased(),
            tareWeightG: tare,
            hasPhoto: false,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Convenience: build a target entry.
    private func target(_ c: Container, _ count: Int) -> PrepModel.TargetEntry {
        .init(container: c, count: count)
    }

    /// Convenience: build a weigh-in.
    private func weighIn(_ c: Container, _ gross: Double?) -> PrepModel.WeighIn {
        .init(container: c, grossGrams: gross)
    }

    /// containerCount comes from a single entry's multiplier.
    func testContainerCountFromMultiplier() {
        let m = PrepModel()
        m.targets = [target(mkContainer(tare: 100), 5)]
        XCTAssertEqual(m.containerCount, 5)
    }

    /// containerCount sums across multiple entries.
    func testContainerCountSumsEntries() {
        let m = PrepModel()
        m.targets = [target(mkContainer(tare: 80), 2), target(mkContainer(tare: 412), 3)]
        XCTAssertEqual(m.containerCount, 5)
    }

    /// portions defaults to containerCount when no override is set.
    func testPortionsDefaultsToContainerCount() {
        let m = PrepModel()
        m.targets = [target(mkContainer(tare: 100), 5)]
        XCTAssertEqual(m.portions, 5)
    }

    /// portionsOverride decouples portions from containerCount.
    func testPortionsOverrideDecouples() {
        let m = PrepModel()
        m.targets = [target(mkContainer(tare: 100), 5)]
        m.portionsOverride = 10
        XCTAssertEqual(m.portions, 10)
        XCTAssertEqual(m.containerCount, 5)
    }

    /// portions is at least 1 even with no targets and no override (no divide-by-zero).
    func testPortionsAtLeastOneWhenEmpty() {
        let m = PrepModel()
        XCTAssertEqual(m.portions, 1)
    }

    /// totalNet is the sum of (gross - tare) across weigh-ins.
    func testTotalNetSumsWeighIns() {
        let m = PrepModel()
        let c = mkContainer(tare: 80)
        m.weighIns = [weighIn(c, 500), weighIn(c, 600)]
        XCTAssertEqual(m.totalNetGrams ?? -1, 940, accuracy: 0.001) // 420 + 520
    }

    /// totalNet, perPortion, and perContainerNet are nil until a gross is entered.
    func testNilUntilGrossEntered() {
        let m = PrepModel()
        m.targets = [target(mkContainer(tare: 100), 3)]
        m.weighIns = [weighIn(mkContainer(tare: 80), nil)]
        XCTAssertNil(m.totalNetGrams)
        XCTAssertNil(m.perPortionGrams)
        XCTAssertNil(m.perContainerNetGrams)
    }

    /// A weigh-in whose tare exceeds its gross contributes 0, not a negative.
    func testNegativeNetClampsPerRow() {
        let m = PrepModel()
        m.weighIns = [weighIn(mkContainer(tare: 1000), 500)]
        XCTAssertEqual(m.totalNetGrams, 0)
    }

    /// perContainerNet is an even split of total net across containerCount.
    func testPerContainerNetEvenSplit() {
        let m = PrepModel()
        let c = mkContainer(tare: 100)
        m.targets = [target(c, 5)]
        m.weighIns = [weighIn(c, 1100)] // net 1000
        XCTAssertEqual(m.perContainerNetGrams ?? -1, 200, accuracy: 0.001)
    }

    /// perContainerNet is nil when there are no targets.
    func testPerContainerNetNilWhenNoTargets() {
        let m = PrepModel()
        m.weighIns = [weighIn(mkContainer(tare: 100), 1100)]
        XCTAssertNil(m.perContainerNetGrams)
    }

    /// Uniform-tare targets: targetGross = perContainerNet + tare; flag is true.
    func testTargetGrossUniform() {
        let m = PrepModel()
        let c = mkContainer(tare: 100)
        m.targets = [target(c, 5)]
        m.weighIns = [weighIn(c, 1100)] // net 1000, perContainer 200
        XCTAssertTrue(m.targetTaresAreUniform)
        XCTAssertEqual(m.targetGross(for: m.targets[0]) ?? -1, 300, accuracy: 0.001)
    }

    /// Mixed-tare targets: per-entry targetGross differs; flag is false.
    func testTargetGrossMixedTares() {
        let m = PrepModel()
        let small = mkContainer(tare: 80, name: "Small")
        let pyrex = mkContainer(tare: 412, name: "Pyrex")
        m.targets = [target(small, 2), target(pyrex, 1)] // containerCount 3
        m.weighIns = [weighIn(small, 1079)] // net 999, perContainer 333
        XCTAssertFalse(m.targetTaresAreUniform)
        XCTAssertEqual(m.targetGross(for: m.targets[0]) ?? -1, 413, accuracy: 0.001)
        XCTAssertEqual(m.targetGross(for: m.targets[1]) ?? -1, 745, accuracy: 0.001)
    }

    /// reconcile refreshes a target's container snapshot (e.g. tare edited).
    func testReconcileRefreshesTare() {
        let id = UUID()
        let m = PrepModel()
        m.targets = [target(mkContainer(tare: 100, id: id), 2)]
        let updated = mkContainer(tare: 150, id: id)
        m.reconcile(with: [updated])
        XCTAssertEqual(m.targets.first?.container.tareWeightG, 150)
    }

    /// reconcile drops entries whose container was deleted.
    func testReconcileDropsDeleted() {
        let gone = mkContainer(tare: 100)
        let m = PrepModel()
        m.targets = [target(gone, 2)]
        m.weighIns = [weighIn(gone, 500)]
        m.reconcile(with: []) // container no longer exists
        XCTAssertTrue(m.targets.isEmpty)
        XCTAssertTrue(m.weighIns.isEmpty)
    }

    /// Parity with the old single-container flow: one target ×1, one weigh-in.
    func testParitySingleContainerSingleWeighIn() {
        let m = PrepModel()
        let c = mkContainer(tare: 412)
        m.targets = [target(c, 1)]
        m.weighIns = [weighIn(c, 1450)]
        XCTAssertEqual(m.totalNetGrams ?? -1, 1038, accuracy: 0.001)
        XCTAssertEqual(m.perContainerNetGrams ?? -1, 1038, accuracy: 0.001)
        XCTAssertEqual(m.portions, 1)
        XCTAssertEqual(m.perPortionGrams ?? -1, 1038, accuracy: 0.001)
    }

    /// hasUnenteredWeighIns is true when any weigh-in lacks a gross reading.
    func testHasUnenteredWeighIns() {
        let m = PrepModel()
        let c = mkContainer(tare: 80)
        m.weighIns = [weighIn(c, 500), weighIn(c, nil)]
        XCTAssertTrue(m.hasUnenteredWeighIns)
        m.weighIns = [weighIn(c, 500), weighIn(c, 600)]
        XCTAssertFalse(m.hasUnenteredWeighIns)
        m.weighIns = []
        XCTAssertFalse(m.hasUnenteredWeighIns)
    }
}
