import Foundation

extension PulseClient {
    /// Fetch one page of the workout feed, newest first.
    /// - Parameters:
    ///   - before: Opaque `start_time` cursor from the prior page's `nextBefore`; nil for the first page.
    ///   - beforeId: Opaque id tiebreaker from the prior page's `nextBeforeId`; nil for the first page.
    ///   - type: Optional exact `activity_type` filter; nil for all types.
    ///   - group: Optional top-level group filter (`"weights"` or `"cardio"`); nil for all groups.
    ///   - limit: Page size, 1–100 (default 50).
    /// - Returns: A `WorkoutFeedPage` of summaries plus the composite cursor for the next page.
    /// - Throws: `PulseError` on transport, auth, or decoding failure.
    func activityWorkouts(before: String?, beforeId: String?, type: String?,
                          group: String? = nil, limit: Int = 50) async throws -> WorkoutFeedPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        if let beforeId { query.append(URLQueryItem(name: "before_id", value: beforeId)) }
        if let type { query.append(URLQueryItem(name: "type", value: type)) }
        if let group { query.append(URLQueryItem(name: "group", value: group)) }
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

    /// Fetch the list of all activity types with their current cardio classification
    /// and workout count (`GET /activity/types`).
    /// - Returns: An `ActivityTypesResponse` containing every distinct activity type
    ///   found in imported workouts.
    /// - Throws: `PulseError` on transport, auth, or decoding failure.
    func activityTypes() async throws -> ActivityTypesResponse {
        let url = try http.makeURL(path: "/activity/types", query: [])
        return try await fetch(url: url)
    }

    /// Update the cardio classification for one activity type
    /// (`PUT /activity/types/{activityType}`).
    /// The path segment is percent-encoded so types that contain spaces or
    /// special characters round-trip safely, even though current types are
    /// bare camelCase strings like "Running".
    /// - Parameters:
    ///   - activityType: The raw `activity_type` string to update (e.g. `"Running"`).
    ///   - isCardio: Whether this type should be classified as cardio.
    /// - Returns: The updated `ActivityTypeSetting` as persisted by the server.
    /// - Throws: `PulseError.notFound` when the type does not exist; other
    ///   `PulseError` on transport, auth, or decoding failure.
    func setActivityTypeCardio(_ activityType: String, isCardio: Bool) async throws -> ActivityTypeSetting {
        let encoded = activityType.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? activityType
        let url = try http.makeURL(path: "/activity/types/\(encoded)", query: [])
        let body = try JSONEncoder.pulseDefault().encode(SetActivityTypeCardioRequest(isCardio: isCardio))
        return try await sendJSON(url: url, method: "PUT", body: body)
    }
}

// MARK: - Private request bodies

/// Request body for `PUT /activity/types/{activity_type}`.
private struct SetActivityTypeCardioRequest: Encodable {
    /// Whether the type should be classified as cardio.
    let isCardio: Bool
    enum CodingKeys: String, CodingKey {
        case isCardio = "is_cardio"
    }
}
