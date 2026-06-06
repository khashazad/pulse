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

    /// Batch food items round-trip through UserDefaults independently of the
    /// container-resolution path (items store everything they need).
    func test_batchItems_roundTrip() {
        let defaults = UserDefaults(suiteName: "prep.batch.test.\(UUID().uuidString)")!
        let store = PrepStatePersistence(defaults: defaults)
        let item = BatchFoodItem(
            id: UUID(), displayName: "White rice", usdaFdcId: 169756, usdaDescription: "Rice",
            customFoodId: nil,
            nutrition: FoodNutrition(basis: .per100g, servingSize: nil, servingSizeUnit: nil,
                                     caloriesPerBasis: 130, proteinGPerBasis: 2.7, carbsGPerBasis: 28, fatGPerBasis: 0.3),
            quantity: .typed(value: 200, unit: .grams), containerId: nil,
            macros: MacroTotals(calories: 260, proteinG: 5.4, carbsG: 56, fatG: 0.6))
        store.saveBatchItems([item])
        XCTAssertEqual(store.loadBatchItems(), [item])
    }

    /// Loading with nothing saved yields an empty array.
    func test_batchItems_emptyByDefault() {
        let defaults = UserDefaults(suiteName: "prep.batch.empty.\(UUID().uuidString)")!
        XCTAssertEqual(PrepStatePersistence(defaults: defaults).loadBatchItems(), [])
    }

    /// Applied day keys round-trip through save/load.
    func testAppliedDatesRoundTrip() {
        let store = PrepStatePersistence(defaults: makeDefaults())
        XCTAssertEqual(store.loadAppliedDates(), [])
        store.saveAppliedDates(["2026-06-07", "2026-06-08"])
        XCTAssertEqual(store.loadAppliedDates(), ["2026-06-07", "2026-06-08"])
    }
}
