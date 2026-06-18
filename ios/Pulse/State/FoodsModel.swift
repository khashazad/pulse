// Pulse/State/FoodsModel.swift
/// FoodsModel: view-model backing the Food tab's "Foods" section once foods can
/// be grouped. Loads the grouped browse (`GET /foods`) and the flat custom-food
/// list (`GET /custom-foods`) concurrently — the flat list resolves a tapped
/// portion back to its full editable `CustomFood` and seeds the grouping picker.
/// Local apply helpers reflect detail-screen and grouping edits without a full
/// refetch, and `ungroup` owns the delete-side network + restore.
import Foundation
import Observation

/// Observable view-model loading the grouped Foods browse.
@Observable
final class FoodsModel {
    private(set) var state: LoadState<FoodList> = .idle
    /// Every custom food (portions + standalones) by id, from the flat list.
    private(set) var customFoodsById: [UUID: CustomFood] = [:]
    /// Possible grouping candidates among the current standalones, recomputed once
    /// per loaded-state change (never in the view body). Drives the duplicates hint.
    private(set) var duplicateClusters: [[CustomFood]] = []
    private weak var auth: AuthSession?

    /// Initializes the grouped-foods model.
    /// Inputs:
    ///   - auth: auth session used to construct an authenticated client.
    init(auth: AuthSession) {
        self.auth = auth
    }

    /// Loads the grouped browse and flat custom-food list concurrently. Never
    /// throws; failures surface through `state` (`.notSignedIn`, `.unauthorized`
    /// — also routed through `AuthSession.handleUnauthorized()` — or `.server`).
    /// The browse drives `state`; the flat list only feeds `customFoodsById`, so
    /// a flat-list failure does not by itself fail the browse.
    /// Outputs: nothing; results are reflected in `state` and `customFoodsById`.
    func load() async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notSignedIn)
            return
        }
        state = .loading
        async let browseResult = client.listFoods()
        async let flatResult = client.listCustomFoods()
        do {
            let browse = try await browseResult
            if let flat = try? await flatResult {
                customFoodsById = Dictionary(uniqueKeysWithValues: flat.map { ($0.id, $0) })
            }
            setLoaded(browse)
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    /// Resolves a portion's `customFoodId` to its full editable custom food.
    /// Inputs:
    ///   - id: the portion's custom-food UUID.
    /// Outputs: the matching `CustomFood`, or nil when not yet loaded / unknown.
    func customFood(for id: UUID) -> CustomFood? {
        customFoodsById[id]
    }

    /// Ungroups a food: deletes the parent on the server, then restores its
    /// portions as standalones by resolving each through `customFoodsById`. Falls
    /// back to a full reload if a portion can't be resolved or the request fails,
    /// keeping the browse consistent. No-op when there is no signed-in client.
    /// Inputs:
    ///   - food: the grouped food to dissolve.
    /// Outputs: nothing; updates `state` via `applyUngrouped` or `load`.
    func ungroup(_ food: Food) async {
        guard let client = auth?.makeClient() else { return }
        do {
            try await client.ungroupFood(id: food.id)
            let restored = food.portions.compactMap { customFoodsById[$0.customFoodId] }
            if restored.count == food.portions.count {
                applyUngrouped(foodId: food.id, restored: restored)
            } else {
                await load()
            }
        } catch {
            await load()
        }
    }

    /// Publishes a freshly loaded `FoodList`, recomputing the derived
    /// `duplicateClusters` once so the view never tokenizes standalones in its body.
    /// Inputs:
    ///   - list: the new browse payload to publish.
    /// Outputs: nothing; reassigns `state` and `duplicateClusters`.
    private func setLoaded(_ list: FoodList) {
        duplicateClusters = FoodDuplicateGrouper.clusters(from: list.standalones)
        state = .loaded(list)
    }

    /// Applies an immutable transform to the loaded `FoodList` and republishes it.
    /// No-op unless `state` is `.loaded`.
    /// Inputs:
    ///   - transform: maps the current `FoodList` to its replacement.
    /// Outputs: nothing; republishes via `setLoaded` when loaded.
    private func updateLoaded(_ transform: (FoodList) -> FoodList) {
        guard case .loaded(let browse) = state else { return }
        setLoaded(transform(browse))
    }

    /// Reflects a just-created group locally: inserts the new parent `Food` into
    /// the browse and drops the standalones that were folded into it. No-op
    /// unless `state` is `.loaded`.
    /// Inputs:
    ///   - food: the newly created parent food to add to the browse.
    ///   - groupedIds: ids of standalone custom foods now nested under `food`.
    /// Outputs: nothing; republishes `state` when loaded.
    func applyGrouped(_ food: Food, groupedIds: Set<UUID>) {
        // The grouped ids stay in `customFoodsById` on purpose: `ungroup` restores
        // a dissolved Food's portions to standalones by resolving them through this
        // map, so their full `CustomFood` rows must remain available.
        updateLoaded {
            FoodList(foods: $0.foods + [food],
                     standalones: $0.standalones.filter { !groupedIds.contains($0.id) })
        }
    }

    /// Reflects an ungrouping locally: removes the parent `Food` and restores its
    /// freed portions as standalones. No-op unless `state` is `.loaded`.
    /// Inputs:
    ///   - foodId: id of the parent food being dissolved.
    ///   - restored: custom foods to re-add to the standalone list.
    /// Outputs: nothing; republishes `state` when loaded.
    func applyUngrouped(foodId: UUID, restored: [CustomFood]) {
        updateLoaded {
            FoodList(foods: $0.foods.filter { $0.id != foodId },
                     standalones: $0.standalones + restored)
        }
    }

    // Note on portion (vs standalone) edits from the detail screen:
    //  - RENAME: not reflected in the browse — the label-keyed `FoodGroupRow`
    //    never shows a portion's name — but the `customFoodsById` resolve map IS
    //    kept current (see `applyRenamedStandalone`), so ungroup and portion
    //    re-open use the new name.
    //  - DELETE: the portion is detached from its parent `Food`'s portion list
    //    (see `applyRemovedStandalone`) so the deleted sub-row disappears rather
    //    than lingering as a dead tap (its map entry is purged, so it can't open).

    /// Reflects a custom-food rename locally: always refreshes the `customFoodsById`
    /// lookup entry (so a renamed portion resolves to its new name on ungroup or
    /// re-open), and additionally replaces the matching standalone in the browse
    /// in place when one exists. No-op on the browse when `state` is not `.loaded`
    /// or no standalone matches.
    /// Inputs:
    ///   - food: the updated custom food returned by the rename call.
    /// Outputs: nothing; updates `customFoodsById` unconditionally and republishes
    ///   `state` when loaded and a matching standalone is found.
    func applyRenamedStandalone(_ food: CustomFood) {
        // Keep the resolve map fresh for ANY renamed custom food — including a
        // portion that isn't in the standalone list — so a later ungroup or a
        // re-open of that portion sees the new name, not a stale one.
        customFoodsById[food.id] = food
        guard case .loaded(let browse) = state else { return }
        guard let idx = browse.standalones.firstIndex(where: { $0.id == food.id }) else { return }
        var standalones = browse.standalones
        standalones[idx] = food
        setLoaded(FoodList(foods: browse.foods, standalones: standalones))
    }

    /// Reflects a custom-food deletion locally: removes it from the browse —
    /// dropping a matching standalone, and detaching it from any parent `Food`'s
    /// portion list so a deleted portion's sub-row disappears rather than becoming
    /// an un-openable dead tap — and purges its `customFoodsById` entry. No-op on
    /// the browse unless `.loaded`.
    /// Inputs:
    ///   - id: the deleted custom food's UUID.
    /// Outputs: nothing; republishes `state` and removes the map entry.
    func applyRemovedStandalone(id: UUID) {
        // A deleted food must not remain resolvable via `customFood(for:)`.
        customFoodsById.removeValue(forKey: id)
        updateLoaded { list in
            FoodList(
                foods: list.foods.map { food in
                    guard food.portions.contains(where: { $0.customFoodId == id }) else { return food }
                    return Food(
                        id: food.id, name: food.name, notes: food.notes,
                        defaultPortionId: food.defaultPortionId == id ? nil : food.defaultPortionId,
                        aliases: food.aliases,
                        portions: food.portions.filter { $0.customFoodId != id }
                    )
                },
                standalones: list.standalones.filter { $0.id != id }
            )
        }
    }
}
