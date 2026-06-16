/// `PulseClient` food-domain endpoints: the daily summary, raw log listing,
/// food-entry batch writes and single-entry deletes, USDA search proxy,
/// custom foods, food memory, and custom-food mutations.
/// Pure code organization — every method keeps its original signature and
/// behaviour; only the shared transport now lives on `http`.
import Foundation

/// Request body for `PATCH /custom-foods/{id}`. Only `name` is sent today; the
/// optional field is encoded only when present so an omitted key never appears
/// as `null` (matching the server's partial-update contract).
private struct UpdateCustomFoodRequest: Encodable {
    let name: String?

    enum CodingKeys: String, CodingKey { case name }

    /// Encodes only the non-nil fields so omitted keys do not appear as `null`.
    /// Inputs:
    ///   - encoder: the encoder to write into.
    /// Outputs: nothing.
    /// Exceptions: rethrows any encoding error.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
    }
}

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

    /// Confirms one or more pending food entries (`POST /entries/confirm`).
    /// Pending future prep portions don't count toward any total until confirmed;
    /// this flips them to counted. Pass a single id to confirm one entry, or a
    /// day's pending ids to confirm them all at once. Idempotent on the server.
    /// Inputs:
    ///   - ids: the pending `FoodEntry` UUIDs to confirm (at least one).
    /// Outputs: an `EntryWriteResponse` with the confirmed entries and the
    /// affected day's recomputed (confirmed-only) macro totals.
    /// Exceptions: `PulseError` on transport, status, or decoding failure.
    func confirmEntries(ids: [UUID]) async throws -> EntryWriteResponse {
        let url = try http.makeURL(path: "/entries/confirm", query: [])
        let body = try JSONEncoder.pulseDefault().encode(EntriesConfirmRequest(ids: ids))
        return try await sendJSON(url: url, method: "POST", body: body)
    }

    /// Deletes a single food entry (`DELETE /entries/{id}`).
    /// Inputs:
    ///   - id: the `FoodEntry` UUID to delete.
    /// Outputs: nothing; the server responds 204 on success.
    /// Exceptions: `PulseError` on transport or auth failure; `.notFound` when
    /// the entry does not exist (callers may treat this as already-deleted).
    func deleteEntry(id: UUID) async throws {
        let url = try http.makeURL(path: "/entries/\(id.uuidString.lowercased())", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        http.applyAuth(&req)
        try await sendNoBody(request: req)
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

    /// Renames a custom food (`PATCH /custom-foods/{id}`).
    /// Inputs:
    ///   - id: the custom food's UUID.
    ///   - name: the new display name.
    /// Outputs: the updated `CustomFood` decoded from the response.
    /// Exceptions: `PulseError.server(status: 409)` when the name collides with
    /// another custom food; `.notFound` when the id is not owned; other
    /// `PulseError` on transport, auth, or decoding failure.
    func updateCustomFood(id: UUID, name: String) async throws -> CustomFood {
        let url = try http.makeURL(path: "/custom-foods/\(id.uuidString.lowercased())", query: [])
        let body = try JSONEncoder.pulseDefault().encode(UpdateCustomFoodRequest(name: name))
        return try await sendJSON(url: url, method: "PATCH", body: body)
    }

    /// Deletes a custom food (`DELETE /custom-foods/{id}`).
    /// Inputs:
    ///   - id: the custom food's UUID.
    /// Outputs: nothing; the server responds 204 on success.
    /// Exceptions: `PulseError.server(status: 409)` when the food is still
    /// referenced by past entries or meal items; `.notFound` when the id is not
    /// owned; other `PulseError` on transport or auth failure.
    func deleteCustomFood(id: UUID) async throws {
        let url = try http.makeURL(path: "/custom-foods/\(id.uuidString.lowercased())", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        http.applyAuth(&req)
        try await sendNoBody(request: req)
    }
}
