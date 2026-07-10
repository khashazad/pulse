/// `PulseClient` food-domain endpoints: the daily summary, raw log listing,
/// food-entry batch writes and single-entry deletes, USDA search proxy,
/// custom foods, food memory, and custom-food mutations.
/// Pure code organization — every method keeps its original signature and
/// behaviour; only the shared transport now lives on `http`.
import Foundation

/// Request body for `PATCH /custom-foods/{id}`. Carries the new name; relies on
/// synthesized `Encodable` since the only field is always provided.
private struct UpdateCustomFoodRequest: Encodable {
    let name: String
}

/// Request body for `PUT /logs/{date}/excluded`. Carries the new flag value.
private struct DayExclusionRequest: Encodable {
    let excluded: Bool
}

/// Request body for `POST /foods` (group existing custom foods into a Food).
private struct CreateFoodRequest: Encodable {
    let name: String
    let portionIds: [UUID]
    let defaultPortionId: UUID?
    let portionLabels: [String: String]   // keyed by lowercased portion UUID
    let aliases: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case portionIds = "portion_ids"
        case defaultPortionId = "default_portion_id"
        case portionLabels = "portion_labels"
        case aliases
    }
}

/// Request body for `PATCH /foods/{id}`.
private struct UpdateFoodRequest: Encodable {
    let name: String?
    let defaultPortionId: UUID?
    let aliases: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case defaultPortionId = "default_portion_id"
        case aliases
    }
}

/// Request body for `POST /foods/{id}/portions`.
private struct AddPortionRequestBody: Encodable {
    let customFoodId: UUID
    let portionLabel: String?

    enum CodingKeys: String, CodingKey {
        case customFoodId = "custom_food_id"
        case portionLabel = "portion_label"
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

    /// Moves one or more confirmed food entries back to pending (`POST
    /// /entries/unconfirm`). The inverse of `confirmEntries`: pending entries are
    /// excluded from the day's totals until confirmed again. Idempotent on the
    /// server.
    /// Inputs:
    ///   - ids: the confirmed `FoodEntry` UUIDs to make pending (at least one).
    /// Outputs: an `EntryWriteResponse` with the changed entries and the
    /// affected day's recomputed (confirmed-only) macro totals.
    /// Exceptions: `PulseError` on transport, status, or decoding failure.
    func makePending(ids: [UUID]) async throws -> EntryWriteResponse {
        let url = try http.makeURL(path: "/entries/unconfirm", query: [])
        let body = try JSONEncoder.pulseDefault().encode(EntriesPendingRequest(ids: ids))
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

    /// Sets or clears the "ignore this day from stats" flag for one date
    /// (`PUT /logs/{date}/excluded`). Excluded days still appear in the app but
    /// are skipped by every period average/trend and dimmed in charts. Toggling
    /// never alters the day's own entries or totals.
    /// Inputs:
    ///   - date: the calendar day to toggle.
    ///   - excluded: the new flag value.
    /// Outputs: the day's refreshed `DailySummary`, carrying the new `excluded`.
    /// Exceptions: `PulseError` on transport/auth/decoding failure; `.notFound`
    /// (404) when no target profile exists (same contract as `summary(date:)`).
    func setDayExcluded(date: Date, excluded: Bool) async throws -> DailySummary {
        let url = try http.makeURL(
            path: "/logs/\(DateOnly.string(from: date))/excluded", query: [])
        let body = try JSONEncoder.pulseDefault().encode(DayExclusionRequest(excluded: excluded))
        return try await sendJSON(url: url, method: "PUT", body: body)
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

    /// Lists grouped foods (with nested portions) plus ungrouped standalones.
    /// Outputs: the `FoodList` envelope from `GET /foods`.
    /// Exceptions: `PulseError` on transport/auth/decoding failure.
    func listFoods() async throws -> FoodList {
        let url = try http.makeURL(path: "/foods", query: [])
        return try await fetch(url: url)
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

    // MARK: - grouping / ungrouping

    /// Groups one or more existing custom foods into a new Food (`POST /foods`).
    /// Each referenced custom food becomes a portion of the Food; the portion-label
    /// map lets callers name each portion (e.g. "small", "medium"). Portion-label
    /// keys are lowercased portion UUID strings to match the server contract.
    /// Inputs:
    ///   - name: the display name for the new Food.
    ///   - portionIds: custom-food UUIDs to attach as portions (at least one).
    ///   - defaultPortionId: the portion to represent the Food when collapsed, or
    ///     nil to let the server fall back to the first portion.
    ///   - portionLabels: per-portion labels keyed by portion UUID; the keys are
    ///     lowercased before sending.
    ///   - aliases: alternate names that should resolve to this Food.
    /// Outputs: the created `Food` decoded from the 201 response.
    /// Exceptions: `PulseError.server(status: 409)` when the name collides with an
    /// existing Food; `.notFound` when a referenced custom food is not owned;
    /// other `PulseError` on transport, auth, or decoding failure.
    func createFood(
        name: String, portionIds: [UUID], defaultPortionId: UUID?,
        portionLabels: [UUID: String], aliases: [String]
    ) async throws -> Food {
        let url = try http.makeURL(path: "/foods", query: [])
        // UUID strings are globally unique, so lowercasing cannot collide two
        // distinct keys — the uniqueKeysWithValues init is safe here.
        let labels = Dictionary(uniqueKeysWithValues:
            portionLabels.map { ($0.key.uuidString.lowercased(), $0.value) })
        let body = try JSONEncoder.pulseDefault().encode(CreateFoodRequest(
            name: name, portionIds: portionIds, defaultPortionId: defaultPortionId,
            portionLabels: labels, aliases: aliases))
        return try await sendJSON(url: url, method: "POST", body: body)
    }

    /// Patches a Food's name, default portion, or aliases (`PATCH /foods/{id}`).
    /// Any `nil` field is omitted from the request and left unchanged server-side.
    /// Inputs:
    ///   - id: the Food's UUID.
    ///   - name: the new display name, or nil to leave unchanged.
    ///   - defaultPortionId: the new default portion, or nil to leave unchanged.
    ///   - aliases: the replacement alias list, or nil to leave unchanged.
    /// Outputs: the updated `Food` decoded from the 200 response.
    /// Exceptions: `PulseError.server(status: 409)` when the new name collides with
    /// another Food; `.notFound` when the id is not owned; other `PulseError` on
    /// transport, auth, or decoding failure.
    func updateFood(id: UUID, name: String?, defaultPortionId: UUID?, aliases: [String]?) async throws -> Food {
        let url = try http.makeURL(path: "/foods/\(id.uuidString.lowercased())", query: [])
        let body = try JSONEncoder.pulseDefault().encode(
            UpdateFoodRequest(name: name, defaultPortionId: defaultPortionId, aliases: aliases))
        return try await sendJSON(url: url, method: "PATCH", body: body)
    }

    /// Attaches one existing custom food to a Food as a new portion
    /// (`POST /foods/{id}/portions`).
    /// Inputs:
    ///   - foodId: the Food's UUID.
    ///   - customFoodId: the custom food to attach as a portion.
    ///   - label: an optional portion label (e.g. "large"), or nil for none.
    /// Outputs: the updated `Food` (with the added portion) decoded from the 201 response.
    /// Exceptions: `PulseError.server(status: 409)` when the custom food is already
    /// a portion of a Food; `.notFound` when either id is not owned; other
    /// `PulseError` on transport, auth, or decoding failure.
    func addPortion(foodId: UUID, customFoodId: UUID, label: String?) async throws -> Food {
        let url = try http.makeURL(path: "/foods/\(foodId.uuidString.lowercased())/portions", query: [])
        let body = try JSONEncoder.pulseDefault().encode(
            AddPortionRequestBody(customFoodId: customFoodId, portionLabel: label))
        return try await sendJSON(url: url, method: "POST", body: body)
    }

    /// Detaches one portion from a Food, leaving it a standalone custom food
    /// (`DELETE /foods/{id}/portions/{custom_food_id}`). Unlike most DELETEs this
    /// returns a JSON body — the updated `Food` — so it is sent through the
    /// decoding transport rather than `sendNoBody`.
    /// Inputs:
    ///   - foodId: the Food's UUID.
    ///   - customFoodId: the portion's custom-food UUID to detach.
    /// Outputs: the updated `Food` (without the removed portion) decoded from the
    /// 200 response.
    /// Exceptions: `PulseError.notFound` when either id is not owned; other
    /// `PulseError` on transport, auth, or decoding failure.
    func removePortion(foodId: UUID, customFoodId: UUID) async throws -> Food {
        let url = try http.makeURL(
            path: "/foods/\(foodId.uuidString.lowercased())/portions/\(customFoodId.uuidString.lowercased())",
            query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        http.applyAuth(&req)
        // This DELETE carries no request body (only a response body to decode),
        // so it sets Accept but deliberately no Content-Type.
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await sendDecoded(request: req)
    }

    /// Dissolves a Food (`DELETE /foods/{id}`); its portions revert to standalone
    /// custom foods. The server responds 204 with no body.
    /// Inputs:
    ///   - id: the Food's UUID.
    /// Outputs: nothing.
    /// Exceptions: `PulseError.notFound` when the id is not owned; other
    /// `PulseError` on transport or auth failure.
    func ungroupFood(id: UUID) async throws {
        let url = try http.makeURL(path: "/foods/\(id.uuidString.lowercased())", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        http.applyAuth(&req)
        try await sendNoBody(request: req)
    }
}
