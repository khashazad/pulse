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
    /// Selected parent group, nil = All.
    private(set) var groupFilter: ActivityGroup?
    /// Selected subtype within the group, nil = the whole group.
    private(set) var subtypeFilter: String?

    /// The loaded workouts grouped into Mon–Sun week sections (newest first), cached on
    /// every page append so the view reads it without recomputing the grouping each render.
    private(set) var sections: [WeekSection] = []

    /// All activity types seen across any load (filtered or unfiltered), sorted alphabetically.
    /// Derived from `knownTypes`, which is never cleared on reload, so the filter chips stay
    /// stable while a type filter is active — the user can switch types without tapping "All".
    private(set) var availableTypes: [String] = []

    private var isLoadingMore = false
    private weak var auth: AuthSession?
    private var items: [ActivityWorkoutSummary] = []
    private var seen = Set<UUID>()
    private var knownTypes: Set<String> = []
    private var nextBefore: String?
    private var nextBeforeId: String?
    /// Bumped on every `loadFirst`; an in-flight load/page whose captured value no longer
    /// matches has been superseded (e.g. by a rapid filter change) and must discard its result.
    private var generation = 0

    /// Initializes the model with the app's auth session.
    /// - Parameter auth: The shared auth session used to create authenticated clients.
    init(auth: AuthSession) { self.auth = auth }

    /// Whether more (older) pages remain to load — true while the server returned a cursor.
    var canLoadMore: Bool { nextBefore != nil }

    /// The `(type, group)` query pair for the current filter selection.
    /// - Returns: A tuple where at most one is non-nil: a chosen subtype sends `type`;
    ///   otherwise a chosen group sends `group`; All sends neither.
    private var requestFilter: (type: String?, group: String?) {
        if let subtypeFilter { return (subtypeFilter, nil) }
        if let groupFilter { return (nil, groupFilter.rawValue) }
        return (nil, nil)
    }

    /// Loads the first feed page and the week summary; resets any prior state.
    /// - Returns: Nothing; results publish via `state` and `summary`.
    func loadFirst() async {
        guard let client = auth?.makeClient() else { state = .failed(.notSignedIn); return }
        generation += 1
        let gen = generation
        state = .loading
        items = []; seen = []; nextBefore = nil; nextBeforeId = nil
        async let summaryResult = try? client.activitySummary(period: .week, anchor: nil)
        do {
            let page = try await client.activityWorkouts(
                before: nil, beforeId: nil, type: requestFilter.type, group: requestFilter.group)
            guard gen == generation else { return }   // a newer load superseded this one
            append(page)
            state = .loaded(items)
            let loadedSummary = await summaryResult
            guard gen == generation else { return }
            summary = loadedSummary
        } catch let error as PulseError {
            guard gen == generation else { return }
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            guard gen == generation else { return }
            state = .failed(.server(status: -1))
        }
    }

    /// Loads the next (older) page and appends it, if any remain and not already loading.
    /// - Returns: Nothing; results publish via `state`.
    func loadMore() async {
        guard canLoadMore, !isLoadingMore, let client = auth?.makeClient(), case .loaded = state else { return }
        let gen = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.activityWorkouts(
                before: nextBefore, beforeId: nextBeforeId,
                type: requestFilter.type, group: requestFilter.group)
            guard gen == generation else { return }   // a reload superseded this page; drop it
            append(page)
            state = .loaded(items)
        } catch let error as PulseError {
            guard gen == generation else { return }
            if error == .unauthorized { auth?.handleUnauthorized() }
        } catch { /* keep existing items; transient */ }
    }

    /// Selects a parent group (or All), clears any subtype, and reloads from the first page.
    /// - Parameter group: The group to filter by, or nil for All.
    /// - Returns: Nothing; results publish via `state`.
    func setGroup(_ group: ActivityGroup?) async {
        guard group != groupFilter || subtypeFilter != nil else { return }
        groupFilter = group
        subtypeFilter = nil
        await loadFirst()
    }

    /// Selects a subtype within the current group (nil = whole group) and reloads.
    /// - Parameter type: The activity_type to narrow to, or nil for the whole group.
    /// - Returns: Nothing; results publish via `state`.
    func setSubtype(_ type: String?) async {
        guard type != subtypeFilter else { return }
        subtypeFilter = type
        await loadFirst()
    }

    /// The subtypes seen so far that belong to a group, sorted (for the second chip row).
    /// - Parameter group: The group to list subtypes for.
    /// - Returns: Sorted activity types in that group.
    func availableSubtypes(in group: ActivityGroup) -> [String] {
        availableTypes.filter { ActivityGroup.of($0) == group }
    }

    /// Appends a page's items (de-duplicated by id), advances the cursor, and rebuilds
    /// the cached derived state. Also records every item's `activityType` into `knownTypes`
    /// so filter chips remain stable across filtered reloads.
    /// - Parameter page: The freshly fetched feed page.
    private func append(_ page: WorkoutFeedPage) {
        for w in page.items {
            knownTypes.insert(w.activityType)
            if !seen.contains(w.id) {
                seen.insert(w.id); items.append(w)
            }
        }
        nextBefore = page.nextBefore
        nextBeforeId = page.nextBeforeId
        rebuildDerived()
    }

    /// Rebuilds the cached `sections` and `availableTypes` from the current items and known
    /// types. Called once per page append so the view reads cached values instead of
    /// recomputing the week grouping and type sort on every render of a growing feed.
    /// - Returns: Nothing; updates `sections` and `availableTypes` in place.
    private func rebuildDerived() {
        sections = Self.groupByWeek(items)
        availableTypes = knownTypes.sorted()
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
