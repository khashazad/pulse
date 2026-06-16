// Pulse/State/FoodsModel.swift
/// FoodsModel: view-model backing the Food tab's "Foods" section once foods can
/// be grouped. Loads the grouped browse (`GET /foods`) and the flat custom-food
/// list (`GET /custom-foods`) concurrently — the flat list resolves a tapped
/// portion back to its full editable `CustomFood` and seeds the grouping picker.
/// Replaces `CustomFoodsModel` for this section. Local apply helpers reflect
/// detail-screen and grouping edits without a full refetch.
import Foundation
import Observation

/// Observable view-model loading the grouped Foods browse.
@Observable
final class FoodsModel {
    private(set) var state: LoadState<FoodList> = .idle
    /// Every custom food (portions + standalones) by id, from the flat list.
    private(set) var customFoodsById: [UUID: CustomFood] = [:]
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
            state = .loaded(browse)
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

    /// Reflects a just-created group locally: inserts the new parent `Food` into
    /// the browse and drops the standalones that were folded into it. No-op
    /// unless `state` is `.loaded`. Rebuilds `FoodList` immutably.
    /// Inputs:
    ///   - food: the newly created parent food to add to the browse.
    ///   - groupedIds: ids of standalone custom foods now nested under `food`.
    /// Outputs: nothing; reassigns `state` when loaded.
    func applyGrouped(_ food: Food, groupedIds: Set<UUID>) {
        guard case .loaded(let browse) = state else { return }
        let remaining = browse.standalones.filter { !groupedIds.contains($0.id) }
        state = .loaded(FoodList(foods: browse.foods + [food], standalones: remaining))
        // The grouped ids stay in `customFoodsById` on purpose: `applyUngrouped`
        // restores a dissolved Food's portions to standalones by resolving them
        // through this map, so their full `CustomFood` rows must remain available.
    }

    /// Reflects an ungrouping locally: removes the parent `Food` and restores its
    /// freed portions as standalones. No-op unless `state` is `.loaded`. Rebuilds
    /// `FoodList` immutably.
    /// Inputs:
    ///   - foodId: id of the parent food being dissolved.
    ///   - restored: custom foods to re-add to the standalone list.
    /// Outputs: nothing; reassigns `state` when loaded.
    func applyUngrouped(foodId: UUID, restored: [CustomFood]) {
        guard case .loaded(let browse) = state else { return }
        let foods = browse.foods.filter { $0.id != foodId }
        state = .loaded(FoodList(foods: foods, standalones: browse.standalones + restored))
    }

    // Limitation: `applyRenamedStandalone`/`applyRemovedStandalone` cover the
    // common standalone case driven from the detail screen. Renaming or deleting
    // a *portion* (a custom food nested under a parent `Food`) via the detail
    // screen is intentionally NOT locally applied: the label-keyed browse never
    // surfaces a portion's name, and a portion delete self-heals on the next
    // refresh. We deliberately do not rebuild every `Food`'s portion list here.

    /// Reflects a standalone rename locally: replaces the matching standalone in
    /// place and refreshes its `customFoodsById` lookup entry. No-op when `state`
    /// is not `.loaded`, or when no standalone matches `food.id`. Rebuilds
    /// `FoodList` immutably.
    /// Inputs:
    ///   - food: the updated custom food returned by the rename call.
    /// Outputs: nothing; reassigns `state` and updates `customFoodsById` only when
    ///   loaded and a matching standalone is found.
    func applyRenamedStandalone(_ food: CustomFood) {
        guard case .loaded(let browse) = state else { return }
        guard let idx = browse.standalones.firstIndex(where: { $0.id == food.id }) else { return }
        var standalones = browse.standalones
        standalones[idx] = food
        state = .loaded(FoodList(foods: browse.foods, standalones: standalones))
        customFoodsById[food.id] = food
    }

    /// Reflects a standalone deletion locally: drops the matching standalone from
    /// the browse and purges its `customFoodsById` lookup entry. No-op when
    /// `state` is not `.loaded`. Rebuilds `FoodList` immutably.
    /// Inputs:
    ///   - id: the deleted custom food's UUID.
    /// Outputs: nothing; reassigns `state` and removes the map entry when loaded.
    func applyRemovedStandalone(id: UUID) {
        guard case .loaded(let browse) = state else { return }
        let standalones = browse.standalones.filter { $0.id != id }
        state = .loaded(FoodList(foods: browse.foods, standalones: standalones))
        // A deleted food must not remain resolvable via `customFood(for:)`.
        customFoodsById.removeValue(forKey: id)
    }
}
