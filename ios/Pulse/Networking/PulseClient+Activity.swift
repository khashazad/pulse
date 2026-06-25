import Foundation

extension PulseClient {
    /// Fetch one page of the workout feed, newest first.
    /// - Parameters:
    ///   - before: Opaque `start_time` cursor from the prior page's `nextBefore`; nil for the first page.
    ///   - beforeId: Opaque id tiebreaker from the prior page's `nextBeforeId`; nil for the first page.
    ///   - type: Optional exact `activity_type` filter; nil for all types.
    ///   - limit: Page size, 1–100 (default 50).
    /// - Returns: A `WorkoutFeedPage` of summaries plus the composite cursor for the next page.
    /// - Throws: `PulseError` on transport, auth, or decoding failure.
    func activityWorkouts(before: String?, beforeId: String?, type: String?,
                          limit: Int = 50) async throws -> WorkoutFeedPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        if let beforeId { query.append(URLQueryItem(name: "before_id", value: beforeId)) }
        if let type { query.append(URLQueryItem(name: "type", value: type)) }
        let url = try http.makeURL(path: "/activity/workouts", query: query)
        return try await fetch(url: url)
    }

    /// Fetch full detail for one workout, including Hevy sets when linked.
    /// - Parameter id: The workout's `apple_workouts.id`.
    /// - Returns: The `ActivityWorkoutDetail`.
    /// - Throws: `PulseError.notFound` when the workout does not exist; other `PulseError` on failure.
    func activityWorkoutDetail(id: UUID) async throws -> ActivityWorkoutDetail {
        let url = try http.makeURL(path: "/activity/workouts/\(id.uuidString.lowercased())", query: [])
        return try await fetch(url: url)
    }

    /// Fetch the week/month/year trend summary for a period.
    /// - Parameters:
    ///   - period: The trend granularity.
    ///   - anchor: A date inside the target period; nil lets the server default to today.
    /// - Returns: The assembled `ActivitySummary`.
    /// - Throws: `PulseError` on transport, auth, or decoding failure.
    func activitySummary(period: ActivityPeriod, anchor: Date?) async throws -> ActivitySummary {
        var query = [URLQueryItem(name: "period", value: period.rawValue)]
        if let anchor { query.append(URLQueryItem(name: "anchor", value: DateOnly.string(from: anchor))) }
        let url = try http.makeURL(path: "/activity/summary", query: query)
        return try await fetch(url: url)
    }
}
