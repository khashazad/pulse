/// MealsModel / MealDetailModel: view-models for the saved-meals feature.
/// MealsModel lists the user's saved meal summaries; MealDetailModel loads a
/// single meal's full payload (items, macros) for the detail screen.
/// Role: backing models for the Meals tab and meal detail view.
import Foundation
import Observation

/// Observable view-model that loads the list of the user's saved meal summaries.
@Observable
final class MealsModel {
    private(set) var state: LoadState<[MealSummary]> = .idle
    private weak var auth: AuthSession?

    /// Initializes the meals list model.
    /// Inputs:
    ///   - auth: auth session used to construct an authenticated client.
    init(auth: AuthSession) {
        self.auth = auth
    }

    /// Fetches the meals list and updates `state`; routes 401 through AuthSession.
    func load() async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notSignedIn)
            return
        }
        state = .loading
        do {
            let meals = try await client.meals()
            state = .loaded(meals)
        } catch let error as DietTrackerError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }
}

/// Observable view-model that loads a single saved meal's full payload by id.
@Observable
final class MealDetailModel {
    let mealId: UUID
    private(set) var state: LoadState<Meal> = .idle
    private weak var auth: AuthSession?

    /// Initializes the detail model for a specific meal id.
    /// Inputs:
    ///   - mealId: the meal to load.
    ///   - auth: auth session used to construct an authenticated client.
    init(mealId: UUID, auth: AuthSession) {
        self.mealId = mealId
        self.auth = auth
    }

    /// Fetches the meal payload; keeps stale data on failure if already loaded; routes 401 through AuthSession.
    func load() async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notSignedIn)
            return
        }
        if case .loaded = state {} else { state = .loading }
        do {
            let fresh = try await client.meal(id: mealId)
            state = .loaded(fresh)
        } catch let error as DietTrackerError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            if case .loaded = state { return }
            state = .failed(error)
        } catch {
            if case .loaded = state { return }
            state = .failed(.server(status: -1))
        }
    }
}
