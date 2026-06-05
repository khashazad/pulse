/// `PulseClient` food-domain endpoints: the daily summary, raw log listing,
/// food-entry batch writes, USDA search proxy, custom foods, and food memory.
/// Pure code organization — every method keeps its original signature and
/// behaviour; only the shared transport now lives on `http`.
import Foundation

extension PulseClient {
    // MARK: - read

    /// Fetches the daily summary (totals + entries) for one date.
    /// Inputs:
    ///   - date: the calendar date to summarize.
    /// Outputs: `DailySummary` payload from `/summary/{date}`.
    /// Exceptions: `PulseError` for transport, auth, or decoding failures.
    func summary(date: Date) async throws -> DailySummary {
        let url = try http.makeURL(path: "/summary/\(DateOnly.string(from: date))", query: [])
        return try await fetch(url: url)
    }

    /// Lists raw food log entries between two dates inclusive.
    /// Inputs:
    ///   - from: start date.
    ///   - to: end date.
    /// Outputs: `LogsList` envelope from `/logs`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func logs(from: Date, to: Date) async throws -> LogsList {
        let url = try http.makeURL(
            path: "/logs",
            query: [
                URLQueryItem(name: "from", value: DateOnly.string(from: from)),
                URLQueryItem(name: "to", value: DateOnly.string(from: to))
            ]
        )
        return try await fetch(url: url)
    }

    // MARK: - entry logging (writes)

    /// Creates one or more food entries in a single atomic batch (`POST /entries`).
    /// When an item carries `consumedAt`, the server backdates it to the owning
    /// calendar day derived from that value; the client never computes the log
    /// date itself. All items in the batch share one server-assigned entry group.
    /// Inputs:
    ///   - items: the food entries to create (each built via `FoodEntryCreate.usda`/`.custom`).
    /// Outputs: an `EntryWriteResponse` with the created entries and the affected day's macro totals.
    /// Exceptions: `PulseError` on transport, status (e.g. `.server(status: 422)` for an
    /// unowned `customFoodId`), or decoding failure.
    func createEntries(_ items: [FoodEntryCreate]) async throws -> EntryWriteResponse {
        let url = try http.makeURL(path: "/entries", query: [])
        let body = try JSONEncoder.pulseDefault().encode(EntriesCreateRequest(items: items))
        return try await sendJSON(url: url, method: "POST", body: body)
    }

    // MARK: - food search

    /// Searches USDA FoodData Central via the server proxy.
    /// Inputs:
    ///   - query: search phrase (sent as `q`).
    ///   - limit: max results, 1...25.
    /// Outputs: normalized USDA hits (macros per-100g).
    /// Exceptions: `PulseError` on transport/auth/decoding; `.server(status: 429)` when rate-limited.
    func searchUSDA(query: String, limit: Int) async throws -> [USDAFoodResult] {
        let url = try http.makeURL(path: "/usda/search", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ])
        let resp: USDASearchResponse = try await fetch(url: url)
        return resp.results
    }

    /// Lists the user's custom foods.
    /// Outputs: the array unwrapped from the `CustomFoodList` envelope.
    /// Exceptions: `PulseError` on transport/auth/decoding failure.
    func listCustomFoods() async throws -> [CustomFood] {
        let url = try http.makeURL(path: "/custom-foods", query: [])
        let list: CustomFoodList = try await fetch(url: url)
        return list.customFoods
    }

    /// Lists the user's food-memory entries.
    /// Outputs: the array unwrapped from the `FoodMemoryList` envelope.
    /// Exceptions: `PulseError` on transport/auth/decoding failure.
    func listFoodMemory() async throws -> [FoodMemoryEntry] {
        let url = try http.makeURL(path: "/food-memory", query: [])
        let list: FoodMemoryList = try await fetch(url: url)
        return list.entries
    }
}
