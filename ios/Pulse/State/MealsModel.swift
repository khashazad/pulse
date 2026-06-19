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

    /// Removes a meal from the loaded list in place (after a successful delete),
    /// avoiding a full refetch. No-op unless the list is already loaded.
    /// - Parameter id: the deleted meal's id.
    /// - Returns: Nothing.
    func applyRemoval(id: UUID) {
        guard case .loaded(let meals) = state else { return }
        state = .loaded(meals.filter { $0.id != id })
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

    /// Outcome of the most recent edit (rename / delete / item mutation),
    /// surfaced inline by the detail view's edit mode.
    private(set) var editState: EditActionState = .idle

    /// Discrete states of a meal-edit action, separate from the load/log states.
    enum EditActionState: Equatable {
        case idle
        case working
        case failed(PulseError)
    }

    /// Resets the edit action back to idle (e.g. when leaving edit mode).
    /// - Returns: Nothing.
    func resetEditState() {
        editState = .idle
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

    /// Renames the meal, then reloads it so totals/name stay correct.
    /// - Parameter name: the new display name.
    /// - Returns: true on success (caller can fire its list-refresh callback).
    @discardableResult
    func rename(to name: String) async -> Bool {
        await mutate { client in _ = try await client.updateMeal(id: mealId, name: name) }
    }

    /// Deletes the meal.
    /// - Returns: true on success (caller should pop + refresh the list).
    @discardableResult
    func deleteMeal() async -> Bool {
        guard let client = auth?.makeClient() else {
            editState = .failed(.notSignedIn)
            return false
        }
        editState = .working
        do {
            try await client.deleteMeal(id: mealId)
            editState = .idle
            return true
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            editState = .failed(error)
            return false
        } catch {
            editState = .failed(.server(status: -1))
            return false
        }
    }

    /// Adds an item to the meal, then reloads.
    /// - Parameter item: the quantified item to add.
    /// - Returns: true on success.
    @discardableResult
    func addItem(_ item: NewMealItem) async -> Bool {
        await mutate { client in _ = try await client.addMealItem(mealId: mealId, item: item) }
    }

    /// Updates an item's quantity/macros, then reloads.
    /// - Parameters:
    ///   - itemId: the item being changed.
    ///   - item: the rebuilt item carrying the new quantity + macros.
    /// - Returns: true on success.
    @discardableResult
    func updateItem(itemId: UUID, to item: NewMealItem) async -> Bool {
        await mutate { client in
            _ = try await client.updateMealItem(mealId: mealId, itemId: itemId, item: item)
        }
    }

    /// Removes an item from the meal, then reloads.
    /// - Parameter itemId: the item to remove.
    /// - Returns: true on success.
    @discardableResult
    func deleteItem(itemId: UUID) async -> Bool {
        await mutate { client in try await client.deleteMealItem(mealId: mealId, itemId: itemId) }
    }

    /// Runs an edit action against an authenticated client, sets `editState`,
    /// and reloads the meal on success. Routes 401 through `AuthSession`.
    /// - Parameter action: the client call to perform.
    /// - Returns: true on success.
    private func mutate(_ action: (PulseClient) async throws -> Void) async -> Bool {
        guard let client = auth?.makeClient() else {
            editState = .failed(.notSignedIn)
            return false
        }
        editState = .working
        do {
            try await action(client)
            // Stay in `.working` across the reload so the edit UI shows progress
            // until fresh totals land; only then clear to `.idle`.
            await load()
            editState = .idle
            return true
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            editState = .failed(error)
            return false
        } catch {
            editState = .failed(.server(status: -1))
            return false
        }
    }
}
