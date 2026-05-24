/// Unit tests for `PrepStatePersistence`, the UserDefaults-backed store for the
/// Prep screen's transient calculator state. Verifies save/load round-trips,
/// dropping of deleted container ids, override clearing, and last-used resolution.
import XCTest
@testable import Pulse

final class PrepStatePersistenceTests: XCTestCase {

    /// Builds an isolated UserDefaults suite so tests don't touch real storage.
    /// Outputs: a fresh, empty `UserDefaults`.
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.prep.\(UUID().uuidString)")!
    }

    /// Builds a `Container` fixture.
    /// Inputs:
    ///   - tare: tare weight in grams.
    ///   - id: container id, defaulting to a fresh UUID.
    /// Outputs: a `Container`.
    private func mkContainer(tare: Double, id: UUID = UUID()) -> Container {
        Container(
            id: id, userKey: "khash", name: "C", normalizedName: "c",
            tareWeightG: tare, hasPhoto: false,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Save then load reproduces targets, weigh-ins, and override.
    func testSaveLoadRoundTrip() {
        let d = makeDefaults()
        let store = PrepStatePersistence(defaults: d)
        let c = mkContainer(tare: 100)
        store.save(
            targets: [.init(container: c, count: 5)],
            weighIns: [.init(container: c, grossGrams: 600)],
            portionsOverride: 8
        )
        let loaded = store.load(matching: [c])
        XCTAssertEqual(loaded.targets.count, 1)
        XCTAssertEqual(loaded.targets.first?.count, 5)
        XCTAssertEqual(loaded.targets.first?.container.id, c.id)
        XCTAssertEqual(loaded.weighIns.count, 1)
        XCTAssertEqual(loaded.weighIns.first?.grossGrams, 600)
        XCTAssertEqual(loaded.portionsOverride, 8)
    }

    /// Load drops saved entries whose container id is no longer present.
    func testLoadDropsUnknownContainerIds() {
        let d = makeDefaults()
        let store = PrepStatePersistence(defaults: d)
        let gone = mkContainer(tare: 100)
        store.save(
            targets: [.init(container: gone, count: 2)],
            weighIns: [.init(container: gone, grossGrams: 500)],
            portionsOverride: nil
        )
        let loaded = store.load(matching: []) // gone no longer exists
        XCTAssertTrue(loaded.targets.isEmpty)
        XCTAssertTrue(loaded.weighIns.isEmpty)
    }

    /// A nil override clears the stored key (loads back as nil).
    func testNilOverrideClears() {
        let d = makeDefaults()
        let store = PrepStatePersistence(defaults: d)
        let c = mkContainer(tare: 100)
        store.save(targets: [.init(container: c, count: 1)], weighIns: [], portionsOverride: 9)
        store.save(targets: [.init(container: c, count: 1)], weighIns: [], portionsOverride: nil)
        XCTAssertNil(store.load(matching: [c]).portionsOverride)
    }

    /// Last-used weigh-in container round-trips and resolves against the list.
    func testLastWeighInRoundTrip() {
        let d = makeDefaults()
        let store = PrepStatePersistence(defaults: d)
        let c = mkContainer(tare: 100)
        store.rememberLastWeighIn(c)
        XCTAssertEqual(store.lastWeighInContainer(in: [c])?.id, c.id)
        XCTAssertNil(store.lastWeighInContainer(in: [])) // dropped when absent
    }
}
