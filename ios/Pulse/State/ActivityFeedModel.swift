import Foundation

/// Feed view model: paginates the workout feed, groups loaded workouts into
/// week sections, applies an optional type filter, and loads the week summary strip.
@Observable
final class ActivityFeedModel {
    /// One Mon–Sun group of workouts, newest workout first.
    struct WeekSection: Identifiable {
        let weekStart: Date
        let workouts: [ActivityWorkoutSummary]
        var id: Date { weekStart }
    }

    private(set) var state: LoadState<[ActivityWorkoutSummary]> = .idle
    private(set) var summary: ActivitySummary?
    private(set) var isLoadingMore = false
    private(set) var filter: String?            // nil = All

    private weak var auth: AuthSession?
    private var items: [ActivityWorkoutSummary] = []
    private var seen = Set<UUID>()
    private var nextBefore: String?
    private var nextBeforeId: String?
    private var hasMore = true

    /// Initializes the model with the app's auth session.
    /// - Parameter auth: The shared auth session used to create authenticated clients.
    init(auth: AuthSession) { self.auth = auth }

    /// Whether more (older) pages remain to load.
    var canLoadMore: Bool { hasMore }

    /// The currently loaded workouts grouped into week sections (for the list).
    var sections: [WeekSection] { Self.groupByWeek(items) }

    /// The distinct activity types seen so far, for filter chips (sorted).
    var availableTypes: [String] { Array(Set(items.map(\.activityType))).sorted() }

    /// Loads the first feed page and the week summary; resets any prior state.
    /// - Returns: Nothing; results publish via `state` and `summary`.
    func loadFirst() async {
        guard let client = auth?.makeClient() else { state = .failed(.notSignedIn); return }
        state = .loading
        items = []; seen = []; nextBefore = nil; nextBeforeId = nil; hasMore = true
        async let summaryResult = try? client.activitySummary(period: .week, anchor: nil)
        do {
            let page = try await client.activityWorkouts(before: nil, beforeId: nil, type: filter)
            append(page)
            state = .loaded(items)
            summary = await summaryResult
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    /// Loads the next (older) page and appends it, if any remain and not already loading.
    /// - Returns: Nothing; results publish via `state`.
    func loadMore() async {
        guard hasMore, !isLoadingMore, let client = auth?.makeClient(), case .loaded = state else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.activityWorkouts(before: nextBefore, beforeId: nextBeforeId, type: filter)
            append(page)
            state = .loaded(items)
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
        } catch { /* keep existing items; transient */ }
    }

    /// Sets the active type filter and reloads from the first page.
    /// - Parameter type: An `activity_type` to filter by, or nil for All.
    func setFilter(_ type: String?) async {
        guard type != filter else { return }
        filter = type
        await loadFirst()
    }

    /// Appends a page's items (de-duplicated) and advances the cursor.
    /// - Parameter page: The freshly fetched feed page.
    private func append(_ page: WorkoutFeedPage) {
        for w in page.items where !seen.contains(w.id) {
            seen.insert(w.id); items.append(w)
        }
        nextBefore = page.nextBefore
        nextBeforeId = page.nextBeforeId
        hasMore = page.nextBefore != nil
    }

    /// Groups workouts into Mon–Sun week sections, newest week and workout first.
    /// - Parameters:
    ///   - workouts: The workouts to group (any order).
    ///   - calendar: Calendar for week-start math (defaults to current; Monday-first applied).
    /// - Returns: Week sections sorted newest-first, each holding its workouts newest-first.
    static func groupByWeek(_ workouts: [ActivityWorkoutSummary],
                            calendar: Calendar = .current) -> [WeekSection] {
        guard !workouts.isEmpty else { return [] }
        var cal = calendar
        cal.firstWeekday = 2 // Monday, matching the server's Mon-Sun period bounds
        var buckets: [Date: [ActivityWorkoutSummary]] = [:]
        for w in workouts {
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: w.startTime)
            let weekStart = cal.date(from: comps) ?? cal.startOfDay(for: w.startTime)
            buckets[weekStart, default: []].append(w)
        }
        return buckets
            .map { WeekSection(weekStart: $0.key,
                               workouts: $0.value.sorted { $0.startTime > $1.startTime }) }
            .sorted { $0.weekStart > $1.weekStart }
    }
}
