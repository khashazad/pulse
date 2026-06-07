// Pulse/State/FoodSearchModel.swift
/// Observable search model for the Prep food picker. Loads and caches the
/// user's custom foods + food memory once, then on each (debounced) query runs
/// a live USDA search and merges it with the locally-filtered my-foods set via
/// `FoodSearchMerge`. USDA failures degrade gracefully: my-foods still show.
/// When the query is empty the model shows the full my-foods set sorted
/// alphabetically (browse mode) rather than a blank sheet; `.idle` only occurs
/// before `loadMyFoods()` has completed.
import Foundation
import Observation

/// View-model backing `FoodSearchSheet`. Main-actor isolated so its observable
/// state is only ever published from the main thread (search runs in a detached
/// debounce `Task`, which inherits this actor).
@MainActor
@Observable
final class FoodSearchModel {
    /// Current results: alphabetically-sorted my-foods when the query is blank
    /// (browse mode), filtered+merged results when the user is typing, or
    /// `.idle` before `loadMyFoods()` has been called.
    private(set) var state: LoadState<[FoodSearchResult]> = .idle
    /// True when the last USDA call failed; the sheet shows a non-fatal note.
    private(set) var usdaUnavailable = false
    /// Bound to the search field; mutating it (re)schedules a debounced search.
    var query: String = "" {
        didSet { scheduleSearch() }
    }

    private var myFoods: [FoodSearchResult] = []
    /// Whether `loadMyFoods()` has run (success or failure) at least once, so a
    /// search never merges against an un-loaded my-foods set.
    private var didLoadMyFoods = false
    private weak var auth: AuthSession?
    private var searchTask: Task<Void, Never>?
    private let debounce: Duration

    /// Creates the model.
    /// Inputs:
    ///   - auth: auth session used to build an authenticated client.
    ///   - debounce: delay before a query fires (default 300 ms).
    init(auth: AuthSession, debounce: Duration = .milliseconds(300)) {
        self.auth = auth
        self.debounce = debounce
    }

    /// Loads and caches the user's custom foods + food memory, building the
    /// my-foods set. Call once when the sheet appears. USDA is not touched here.
    /// After loading, if no query is active the state transitions to `.loaded`
    /// with the alphabetically-sorted my-foods so the sheet opens in browse mode.
    func loadMyFoods() async {
        guard let client = auth?.makeClient() else { return }
        defer { didLoadMyFoods = true }
        async let custom = client.listCustomFoods()
        async let memory = client.listFoodMemory()
        do {
            let (c, m) = try await (custom, memory)
            myFoods = FoodSearchMerge.myFoods(customFoods: c, memory: m)
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            myFoods = []
        } catch {
            myFoods = []
        }
        // Surface the browseable my-foods set immediately when no query is
        // active, so the sheet opens onto the user's foods instead of a blank.
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .loaded(Self.alphabetical(myFoods))
        }
    }

    /// Cancels any pending search and schedules a new one after the debounce.
    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            if Task.isCancelled { return }
            await self.runSearch(text)
        }
    }

    /// Runs one search: blank query returns to the alphabetical my-foods browse
    /// list; otherwise runs a live USDA search merged with filtered my-foods.
    /// USDA failure sets `usdaUnavailable` but still renders my-foods.
    /// Inputs:
    ///   - text: the query to search for.
    /// Outputs: none (updates `state` and `usdaUnavailable` as side-effects).
    private func runSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            usdaUnavailable = false
            state = .loaded(Self.alphabetical(myFoods))
            return
        }
        // Ensure my-foods are loaded before merging, so an early keystroke
        // doesn't produce USDA-only results.
        if !didLoadMyFoods { await loadMyFoods() }
        if Task.isCancelled { return }
        state = .loading
        var usda: [USDAFoodResult] = []
        usdaUnavailable = false
        if let client = auth?.makeClient() {
            do {
                usda = try await client.searchUSDA(query: trimmed, limit: 10)
            } catch let error as PulseError {
                if error == .unauthorized { auth?.handleUnauthorized() }
                usdaUnavailable = true
            } catch {
                usdaUnavailable = true
            }
        }
        if Task.isCancelled { return }
        state = .loaded(FoodSearchMerge.results(query: trimmed, myFoods: myFoods, usda: usda))
    }

    /// Alphabetical ordering for the browse (empty-query) list.
    /// Inputs:
    ///   - foods: the unranked my-foods set.
    /// Outputs: foods sorted case-insensitively by display name.
    private static func alphabetical(_ foods: [FoodSearchResult]) -> [FoodSearchResult] {
        foods.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}
