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
}
