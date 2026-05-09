import Foundation
import Observation

@Observable
final class MealsModel {
    private(set) var state: LoadState<[MealSummary]> = .idle
    private weak var auth: AuthSession?

    init(auth: AuthSession) {
        self.auth = auth
    }

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

@Observable
final class MealDetailModel {
    let mealId: UUID
    private(set) var state: LoadState<Meal> = .idle
    private weak var auth: AuthSession?

    init(mealId: UUID, auth: AuthSession) {
        self.mealId = mealId
        self.auth = auth
    }

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
