// PulseTests/FoodsModelApplyTests.swift
import XCTest
@testable import Pulse

/// Tests FoodsModel's local apply helpers (group/ungroup/rename/remove) that
/// reflect detail-screen and grouping edits in `state` without a full refetch.
final class FoodsModelApplyTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private var activeStubs: [StubURLProtocol.Registration] = []
    /// Retains AuthSessions for the test's lifetime: FoodsModel holds `weak var
    /// auth`, so without a strong reference here the session deallocates.
    private var retainedAuths: [AuthSession] = []
    /// Per-test keychain slots written by `makeAuth`, deleted on teardown.
    private var keychainAccounts: [String] = []

    /// Loads a JSON fixture from the test bundle.
    /// Inputs:
    ///   - name: fixture file name without the `.json` extension.
    /// Outputs: the fixture's raw bytes.
    /// Throws: when the resource is missing or unreadable.
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    /// Builds a signed-in `AuthSession` whose client routes `/foods`→`foods.json`
    /// and everything else→`custom_foods.json` with 200s, retaining it for the
    /// test's lifetime. Mirrors `FoodsModelTests`.
    /// Outputs: the signed-in session.
    /// Throws: when a fixture cannot be loaded.
    private func makeAuth() throws -> AuthSession {
        let foods = try fixture("foods")
        let customs = try fixture("custom_foods")
        let stub = StubURLProtocol.makeSession { req in
            let isFoods = req.url?.path == "/foods"
            let body: Data = isFoods ? foods : customs
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        activeStubs.append(stub)
        let account = "fmat-\(UUID().uuidString)"
        keychainAccounts.append(account)
        let auth = AuthSession.signedInStub(
            session: stub.session,
            keychainService: testService,
            keychainAccount: account
        )
        retainedAuths.append(auth)
        return auth
    }

    /// Builds a loaded FoodsModel against the dual-fixture stub.
    /// Outputs: a FoodsModel whose `state` is `.loaded`.
    /// Throws: when a fixture cannot be loaded.
    private func loadedModel() async throws -> FoodsModel {
        let model = FoodsModel(auth: try makeAuth())
        await model.load()
        return model
    }

    /// Builds a standalone CustomFood for assertions.
    /// Inputs:
    ///   - id: the food's UUID.
    ///   - name: the food's display name.
    /// Outputs: a standalone `CustomFood` (no parent, no portion label).
    private func standalone(id: UUID, name: String) -> CustomFood {
        CustomFood(
            id: id, name: name, basis: .perServing,
            servingSize: 1.0, servingSizeUnit: "scoop",
            calories: 130, proteinG: 25.0, carbsG: 3.0, fatG: 1.5,
            foodId: nil, portionLabel: nil
        )
    }

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        retainedAuths = []
        keychainAccounts.forEach { _ = KeychainStore.delete(service: testService, account: $0) }
        keychainAccounts = []
        super.tearDown()
    }

    /// `applyGrouped` inserts the new food and drops grouped standalones.
    func test_applyGrouped_insertsFoodAndRemovesGroupedStandalones() async throws {
        let model = try await loadedModel()
        guard case .loaded(let initial) = model.state else {
            return XCTFail("expected loaded, got \(model.state)")
        }
        let food = initial.foods[0]
        let shakeId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        model.applyGrouped(food, groupedIds: [shakeId])

        guard case .loaded(let after) = model.state else {
            return XCTFail("expected loaded after applyGrouped")
        }
        XCTAssertEqual(after.foods.count, initial.foods.count + 1)
        XCTAssertTrue(after.foods.contains(food))
        XCTAssertFalse(after.standalones.contains { $0.id == shakeId })
    }

    /// `applyUngrouped` removes the food and restores standalones.
    func test_applyUngrouped_removesFoodAndAppendsRestored() async throws {
        let model = try await loadedModel()
        guard case .loaded(let initial) = model.state else {
            return XCTFail("expected loaded, got \(model.state)")
        }
        let food = initial.foods[0]
        let restored = standalone(id: UUID(), name: "Restored Portion")

        model.applyUngrouped(foodId: food.id, restored: [restored])

        guard case .loaded(let after) = model.state else {
            return XCTFail("expected loaded after applyUngrouped")
        }
        XCTAssertFalse(after.foods.contains { $0.id == food.id })
        XCTAssertTrue(after.standalones.contains { $0.id == restored.id })
        XCTAssertEqual(after.standalones.count, initial.standalones.count + 1)
    }

    /// `applyRenamedStandalone` replaces a matching standalone in place.
    func test_applyRenamedStandalone_replacesMatchInPlace() async throws {
        let model = try await loadedModel()
        let shakeId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let renamed = standalone(id: shakeId, name: "Vanilla Shake")

        model.applyRenamedStandalone(renamed)

        guard case .loaded(let after) = model.state else {
            return XCTFail("expected loaded after applyRenamedStandalone")
        }
        XCTAssertEqual(after.standalones.first { $0.id == shakeId }?.name, "Vanilla Shake")
    }

    /// `applyRenamedStandalone` is a no-op when no standalone matches.
    func test_applyRenamedStandalone_absentIsNoOp() async throws {
        let model = try await loadedModel()
        guard case .loaded(let before) = model.state else {
            return XCTFail("expected loaded, got \(model.state)")
        }
        let unknown = standalone(id: UUID(), name: "Ghost")

        model.applyRenamedStandalone(unknown)

        guard case .loaded(let after) = model.state else {
            return XCTFail("expected loaded after applyRenamedStandalone")
        }
        XCTAssertEqual(after.standalones, before.standalones)
    }

    /// `applyRemovedStandalone` removes a matching standalone.
    func test_applyRemovedStandalone_removesMatch() async throws {
        let model = try await loadedModel()
        let shakeId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        model.applyRemovedStandalone(id: shakeId)

        guard case .loaded(let after) = model.state else {
            return XCTFail("expected loaded after applyRemovedStandalone")
        }
        XCTAssertFalse(after.standalones.contains { $0.id == shakeId })
        XCTAssertNil(model.customFood(for: shakeId), "deleted food must not stay resolvable")
    }

    /// `applyRemovedStandalone` is a no-op when no standalone matches.
    func test_applyRemovedStandalone_absentIsNoOp() async throws {
        let model = try await loadedModel()
        guard case .loaded(let before) = model.state else {
            return XCTFail("expected loaded, got \(model.state)")
        }

        model.applyRemovedStandalone(id: UUID())

        guard case .loaded(let after) = model.state else {
            return XCTFail("expected loaded after applyRemovedStandalone")
        }
        XCTAssertEqual(after.standalones, before.standalones)
    }

    /// All helpers are no-ops on a fresh (never-loaded) model: `state` stays
    /// `.idle` and nothing crashes.
    func test_helpers_noOpWhenNotLoaded() throws {
        let model = FoodsModel(auth: try makeAuth())
        let food = Food(
            id: UUID(), name: "X", notes: nil,
            defaultPortionId: nil, aliases: [], portions: []
        )
        let cf = standalone(id: UUID(), name: "Y")

        model.applyGrouped(food, groupedIds: [UUID()])
        model.applyUngrouped(foodId: UUID(), restored: [cf])
        model.applyRenamedStandalone(cf)
        model.applyRemovedStandalone(id: UUID())

        guard case .idle = model.state else {
            return XCTFail("expected idle, got \(model.state)")
        }
    }

    /// Renaming a *portion* (a custom food that is not a standalone) still
    /// refreshes its `customFoodsById` entry, so a later ungroup / re-open
    /// resolves the new name rather than a stale one.
    func test_applyRenamedStandalone_refreshesMapForPortion() async throws {
        let model = try await loadedModel()
        let portionId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let renamed = standalone(id: portionId, name: "renamed portion")

        model.applyRenamedStandalone(renamed)

        XCTAssertEqual(model.customFood(for: portionId)?.name, "renamed portion")
    }

    /// Deleting a *portion* detaches it from its parent `Food` (so the sub-row
    /// disappears instead of becoming a dead tap), clears a default that pointed
    /// at it, and purges the resolve map.
    func test_applyRemovedStandalone_detachesPortionFromParentFood() async throws {
        let model = try await loadedModel()
        let portionId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        model.applyRemovedStandalone(id: portionId)

        guard case .loaded(let after) = model.state else {
            return XCTFail("expected loaded")
        }
        let apple = try XCTUnwrap(after.foods.first { $0.name == "Apple" })
        XCTAssertFalse(apple.portions.contains { $0.customFoodId == portionId })
        XCTAssertEqual(apple.portions.count, 1)
        XCTAssertNil(apple.defaultPortionId, "default pointed at the deleted portion → cleared")
        XCTAssertNil(model.customFood(for: portionId))
    }
}
