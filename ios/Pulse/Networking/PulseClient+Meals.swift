/// `PulseClient` meals-domain endpoints: listing saved meals, fetching a single
/// meal with its items, and logging a saved meal's items as food entries.
/// Pure code organization — signatures and behaviour are unchanged.
import Foundation

extension PulseClient {
    /// Lists all saved meals for the current user.
    /// Outputs: the array unwrapped from the `MealsListResponse` envelope.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func meals() async throws -> [MealSummary] {
        let url = try http.makeURL(path: "/meals", query: [])
        let envelope: MealsListResponse = try await fetch(url: url)
        return envelope.meals
    }

    /// Fetches a single meal with its items.
    /// Inputs:
    ///   - id: meal UUID.
    /// Outputs: the full `Meal`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func meal(id: UUID) async throws -> Meal {
        let url = try http.makeURL(path: "/meals/\(id.uuidString.lowercased())", query: [])
        return try await fetch(url: url)
    }

    /// Logs a saved meal's items as food entries (`POST /meals/{id}/log`). The
    /// meal's items are logged at their saved quantities (no scaling). When
    /// `consumedAt` is set, the server backdates the entries to the owning
    /// calendar day derived from that value; the client never computes the log
    /// date itself.
    /// Inputs:
    ///   - id: the saved meal's id.
    ///   - consumedAt: backdated consumption time, or `nil` to log against the server's "now".
    /// Outputs: an `EntryWriteResponse` with the created entries and the affected day's macro totals.
    /// Exceptions: `PulseError` on transport, status (e.g. `.notFound` for an unknown meal),
    /// or decoding failure.
    func logMeal(id: UUID, consumedAt: Date?) async throws -> EntryWriteResponse {
        let url = try http.makeURL(path: "/meals/\(id.uuidString.lowercased())/log", query: [])
        let body = try JSONEncoder.pulseDefault().encode(LogMealRequest(consumedAt: consumedAt))
        return try await sendJSON(url: url, method: "POST", body: body)
    }
}
