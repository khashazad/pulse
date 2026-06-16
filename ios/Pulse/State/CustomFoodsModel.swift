// Pulse/State/CustomFoodsModel.swift
/// CustomFoodsModel: view-model listing the user's saved custom foods for the
/// Food tab's "Foods" section. Holds the list in memory so the detail screen can
/// apply a rename or removal locally (via `applyRename`/`applyRemoval`) without a
/// full refetch. Mirrors `MealsModel`.
import Foundation
import Observation

/// Observable view-model that loads the user's custom foods and reflects local
/// edits made on the detail screen.
@Observable
final class CustomFoodsModel {
    private(set) var state: LoadState<[CustomFood]> = .idle
    private weak var auth: AuthSession?

    /// Initializes the custom-foods list model.
    /// Inputs:
    ///   - auth: auth session used to construct an authenticated client.
    init(auth: AuthSession) {
        self.auth = auth
    }

    /// Fetches the custom-foods list and updates `state`. Never throws — all
    /// failures are surfaced through `state`: `.failed(.notSignedIn)` when there
    /// is no client, `.failed(.unauthorized)` (also routed through
    /// `AuthSession.handleUnauthorized()`), or `.failed(.server(status:))` for
    /// other errors. On success `state` becomes `.loaded`.
    /// Outputs: nothing; the result is reflected in `state`.
    func load() async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notSignedIn)
            return
        }
        state = .loading
        do {
            let foods = try await client.listCustomFoods()
            state = .loaded(foods)
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    /// Replaces the in-memory copy of a renamed food so the list reflects the
    /// edit immediately without a refetch. No-op unless `state` is `.loaded`.
    /// Inputs:
    ///   - food: the updated custom food returned by the rename call.
    /// Outputs: nothing; mutates `state` in place when loaded.
    func applyRename(_ food: CustomFood) {
        guard case .loaded(var foods) = state else { return }
        guard let idx = foods.firstIndex(where: { $0.id == food.id }) else { return }
        foods[idx] = food
        state = .loaded(foods)
    }

    /// Removes a deleted food from the in-memory list. No-op unless `.loaded`.
    /// Inputs:
    ///   - id: the deleted food's UUID.
    /// Outputs: nothing; mutates `state` in place when loaded.
    func applyRemoval(id: UUID) {
        guard case .loaded(var foods) = state else { return }
        foods.removeAll { $0.id == id }
        state = .loaded(foods)
    }
}
