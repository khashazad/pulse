// Pulse/State/FoodSearchModel.swift
/// Observable search model for the Prep food picker. Loads and caches the
/// user's custom foods + food memory once (concurrent callers coalesce onto
/// the in-flight load; later calls reuse the cache), then on each (debounced)
/// query runs a live USDA search and merges it with the locally-filtered
/// my-foods set via `FoodSearchMerge`. USDA failures degrade gracefully:
/// my-foods still show. When the query is empty the model shows the full
/// my-foods set sorted alphabetically (browse mode); a failed my-foods load
/// in browse mode surfaces as `.failed` so the sheet can offer Retry.
import Foundation
import Observation

/// View-model backing `FoodSearchSheet`. Main-actor isolated so its observable
/// state is only ever published from the main thread (search runs in a detached
/// debounce `Task`, which inherits this actor).
@MainActor
@Observable
final class FoodSearchModel {
    /// Current results: alphabetically-sorted my-foods when the query is blank
    /// (browse mode), filtered+merged results when the user is typing, `.failed`
    /// when the my-foods load failed in browse mode, or `.idle` before
    /// `loadMyFoods()` has been called.
    private(set) var state: LoadState<[FoodSearchResult]> = .idle
    /// True when the last USDA call failed; the sheet shows a non-fatal note.
    private(set) var usdaUnavailable = false
    /// Bound to the search field; mutating it (re)schedules a debounced search.
    var query: String = "" {
        didSet { scheduleSearch() }
    }

    /// True when the active query is blank (whitespace-only included) — the
    /// sheet is browsing my-foods rather than searching. Single source of
    /// truth for browse-vs-search decisions in both the model and the view.
    var isBrowsing: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var myFoods: [FoodSearchResult] = []
    /// Whether `loadMyFoods()` has completed (success or failure) at least
    /// once, so a search never merges against an un-loaded my-foods set.
    private var didLoadMyFoods = false
    /// Whether the last completed my-foods load failed; gates the cached-load
    /// short-circuit in `loadMyFoods()` so `retry()` actually re-fetches.
    private var loadFailed = false
    /// In-flight my-foods load; concurrent callers await it instead of firing
    /// duplicate network requests.
    private var loadTask: Task<Void, Never>?
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
    /// my-foods set. Concurrent calls coalesce onto one in-flight load, and a
    /// previously successful load is reused across sheet presentations
    /// (`retry()` re-fetches after a failure). In browse mode the state
    /// transitions to `.loaded` with the alphabetical my-foods, or `.failed`
    /// when the load failed, so the sheet never strands on a spinner.
    func loadMyFoods() async {
        if didLoadMyFoods && !loadFailed {
            // Cached: re-surface the browse list on sheet re-presentation.
            if isBrowsing { state = .loaded(Self.alphabetical(myFoods)) }
            return
        }
        if loadTask == nil {
            loadTask = Task { await self.performMyFoodsLoad() }
        }
        await loadTask?.value
        loadTask = nil
    }

    /// Performs the actual my-foods fetch and the resulting state transition.
    private func performMyFoodsLoad() async {
        guard let client = auth?.makeClient() else {
            // No client (signed out mid-session): surface the failure instead
            // of leaving the sheet on an endless `.idle` spinner.
            didLoadMyFoods = true
            loadFailed = true
            if isBrowsing { state = .failed(.notSignedIn) }
            return
        }
        async let custom = client.listCustomFoods()
        async let memory = client.listFoodMemory()
        var loadError: PulseError?
        do {
            let (c, m) = try await (custom, memory)
            myFoods = FoodSearchMerge.myFoods(customFoods: c, memory: m)
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            myFoods = []
            loadError = error
        } catch {
            myFoods = []
            loadError = .network(URLError(.unknown))
        }
        didLoadMyFoods = true
        loadFailed = loadError != nil
        // Browse mode: open onto the user's foods, or surface the load failure
        // (with Retry) instead of a misleading "No foods yet" empty state.
        // `isBrowsing` is re-read here so a query typed mid-load is respected.
        if isBrowsing {
            if let loadError {
                state = .failed(loadError)
            } else {
                state = .loaded(Self.alphabetical(myFoods))
            }
        }
    }

    /// Recovers from a failed state: re-fetches my-foods immediately (no
    /// debounce — this is a deliberate tap, not a keystroke) and, when a
    /// query is active, re-runs the search against the fresh set.
    func retry() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.loadMyFoods()
            if Task.isCancelled { return }
            if !self.isBrowsing { await self.runSearch(self.query) }
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

    /// Alphabetical ordering for the browse (empty-query) list — shares
    /// `FoodSearchMerge.nameAscending` with query ranking so the list doesn't
    /// reorder when the user starts typing.
    /// Inputs:
    ///   - foods: the unranked my-foods set.
    /// Outputs: foods sorted case-insensitively by display name.
    private static func alphabetical(_ foods: [FoodSearchResult]) -> [FoodSearchResult] {
        foods.sorted(by: FoodSearchMerge.nameAscending)
    }
}
