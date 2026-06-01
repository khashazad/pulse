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
        } catch let error as PulseError {
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
    /// Outcome of the most recent log attempt, surfaced to the log sheet.
    private(set) var logState: LogActionState = .idle
    private weak var auth: AuthSession?

    /// Discrete states of a meal-log action, separate from the detail-load state
    /// so the log sheet can show progress / success / failure without disturbing
    /// the underlying meal display.
    enum LogActionState: Equatable {
        case idle
        case logging
        case logged(MacroTotals)
        case failed(PulseError)
    }

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
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            if case .loaded = state { return }
            state = .failed(error)
        } catch {
            if case .loaded = state { return }
            state = .failed(.server(status: -1))
        }
    }

    /// Logs this meal's items as food entries, optionally backdated.
    ///
    /// The server logs the meal's items at their saved quantities (no scaling)
    /// and derives the owning calendar day from `consumedAt`; the client never
    /// computes the log date. Updates `logState` for the caller's UI; routes a
    /// 401 through `AuthSession`.
    /// - Parameter consumedAt: Backdated consumption time, or `nil` to log
    ///   against the server's "now".
    /// - Returns: Nothing; the result is reflected in `logState`.
    func logMeal(consumedAt: Date?) async {
        guard let client = auth?.makeClient() else {
            logState = .failed(.notSignedIn)
            return
        }
        logState = .logging
        do {
            let response = try await client.logMeal(id: mealId, consumedAt: consumedAt)
            logState = .logged(response.dailyTotals)
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            logState = .failed(error)
        } catch {
            logState = .failed(.server(status: -1))
        }
    }

    /// Resets the log action back to idle (e.g. when the log sheet is dismissed
    /// or reopened) so stale success/failure state doesn't leak across presentations.
    /// - Returns: Nothing.
    func resetLogState() {
        logState = .idle
    }
}
