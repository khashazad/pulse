/// `PulseClient` weight-domain endpoints: list/get/upsert/delete of weight
/// entries plus the calories-per-day rollup view.
/// Pure code organization — signatures and behaviour (including the
/// `JSONSerialization` weight body) are unchanged.
import Foundation

extension PulseClient {
    /// Lists weight entries between two dates inclusive.
    /// Inputs:
    ///   - from: start date.
    ///   - to: end date.
    /// Outputs: array of `WeightEntry`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func listWeightEntries(from: Date, to: Date) async throws -> [WeightEntry] {
        let url = try http.makeURL(
            path: "/weight",
            query: [
                URLQueryItem(name: "from", value: DateOnly.string(from: from)),
                URLQueryItem(name: "to", value: DateOnly.string(from: to))
            ]
        )
        return try await fetch(url: url)
    }

    /// Fetches the weight entry for a single date.
    /// Inputs:
    ///   - date: calendar date.
    /// Outputs: the `WeightEntry`.
    /// Exceptions: `PulseError`, including `.notFound` if no entry exists.
    func getWeight(date: Date) async throws -> WeightEntry {
        let url = try http.makeURL(path: "/weight/\(DateOnly.string(from: date))", query: [])
        return try await fetch(url: url)
    }

    /// Creates or replaces the weight entry for a date.
    /// Inputs:
    ///   - date: calendar date.
    ///   - weight: numeric weight in `unit`.
    ///   - unit: unit the weight is expressed in.
    /// Outputs: the persisted `WeightEntry`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func upsertWeight(date: Date, weight: Double, unit: WeightUnit) async throws -> WeightEntry {
        let url = try http.makeURL(path: "/weight/\(DateOnly.string(from: date))", query: [])
        let body: [String: Any] = ["weight": weight, "unit": unit.rawValue]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        return try await sendJSON(url: url, method: "PUT", body: data)
    }

    /// Deletes the weight entry for a date.
    /// Inputs:
    ///   - date: calendar date.
    /// Exceptions: `PulseError` on transport or auth failure.
    func deleteWeight(date: Date) async throws {
        let url = try http.makeURL(path: "/weight/\(DateOnly.string(from: date))", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        http.applyAuth(&req)
        try await sendNoBody(request: req)
    }

    /// Fetches the calories-per-day rollup view between two dates inclusive.
    /// Inputs:
    ///   - from: start date.
    ///   - to: end date.
    /// Outputs: array of `CaloriesDailyRow`, one per day with data.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func fetchCaloriesDaily(from: Date, to: Date) async throws -> [CaloriesDailyRow] {
        let url = try http.makeURL(
            path: "/calories_daily",
            query: [
                URLQueryItem(name: "from", value: DateOnly.string(from: from)),
                URLQueryItem(name: "to", value: DateOnly.string(from: to))
            ]
        )
        return try await fetch(url: url)
    }
}
