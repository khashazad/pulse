/// `PulseClient` meals-domain endpoints: listing saved meals, fetching a single
/// meal with its items, and logging a saved meal's items as food entries.
/// Pure code organization — signatures and behaviour are unchanged.
import Foundation

/// Request body for `POST /meals` (create a meal from selected items). Mirrors
/// the server `MealCreate`; `notes`/`aliases` are omitted (server defaults them).
private struct CreateMealRequest: Encodable {
    let name: String
    let items: [NewMealItem]
}

/// Request body for `PATCH /meals/{id}` (rename). Mirrors server `MealUpdate`;
/// only `name` is sent (notes are not edited from iOS).
private struct RenameMealRequest: Encodable {
    let name: String
}

/// Request body for `PATCH /meals/{id}/items/{item_id}`. Mirrors server
/// `MealItemUpdate` — only the mutable fields (no food-source pointer), since
/// the source cannot be changed in place.
private struct UpdateMealItemRequest: Encodable {
    let displayName: String
    let quantityText: String
    let normalizedQuantityValue: Double?
    let normalizedQuantityUnit: String?
    let calories: Int
    let proteinG: Double
    let carbsG: Double
    let fatG: Double

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case quantityText = "quantity_text"
        case normalizedQuantityValue = "normalized_quantity_value"
        case normalizedQuantityUnit = "normalized_quantity_unit"
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
    }

    /// Builds an update body from a quantified `NewMealItem`, dropping the
    /// immutable food-source pointer fields.
    /// Inputs:
    ///   - item: the rebuilt item carrying the new quantity + macros.
    init(item: NewMealItem) {
        self.displayName = item.displayName
        self.quantityText = item.quantityText
        self.normalizedQuantityValue = item.normalizedQuantityValue
        self.normalizedQuantityUnit = item.normalizedQuantityUnit
        self.calories = item.calories
        self.proteinG = item.proteinG
        self.carbsG = item.carbsG
        self.fatG = item.fatG
    }
}

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

    /// Creates a saved meal from a name and a set of items (`POST /meals`). Each
    /// item carries its display name, quantity, food source, and macros; the
    /// server persists them in order and returns the full meal.
    /// Inputs:
    ///   - name: the meal's display name.
    ///   - items: the meal's items (at least one).
    /// Outputs: the created `Meal` decoded from the 201 `MealResponse`.
    /// Exceptions: `PulseError.server(status: 409)` when the name collides with an
    /// existing meal; other `PulseError` on transport, auth, or decoding failure.
    func createMeal(name: String, items: [NewMealItem]) async throws -> Meal {
        let url = try http.makeURL(path: "/meals", query: [])
        let body = try JSONEncoder.pulseDefault().encode(CreateMealRequest(name: name, items: items))
        return try await sendJSON(url: url, method: "POST", body: body)
    }

    /// Renames a saved meal (`PATCH /meals/{id}`).
    /// Inputs:
    ///   - id: the meal's id.
    ///   - name: the new display name.
    /// Outputs: the updated `Meal`.
    /// Exceptions: `PulseError.server(status: 409)` on a name collision; other
    /// `PulseError` on transport, auth, or decoding failure.
    func updateMeal(id: UUID, name: String) async throws -> Meal {
        let url = try http.makeURL(path: "/meals/\(id.uuidString.lowercased())", query: [])
        let body = try JSONEncoder.pulseDefault().encode(RenameMealRequest(name: name))
        return try await sendJSON(url: url, method: "PATCH", body: body)
    }

    /// Deletes a saved meal and its items (`DELETE /meals/{id}`).
    /// Inputs:
    ///   - id: the meal's id.
    /// Outputs: nothing (204 on success).
    /// Exceptions: `PulseError.notFound` for an unknown meal; other `PulseError` on failure.
    func deleteMeal(id: UUID) async throws {
        let url = try http.makeURL(path: "/meals/\(id.uuidString.lowercased())", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        http.applyAuth(&req)
        try await sendNoBody(request: req)
    }

    /// Appends an item to a saved meal (`POST /meals/{id}/items`).
    /// Inputs:
    ///   - mealId: the owning meal's id.
    ///   - item: the quantified item to add.
    /// Outputs: the created `MealItem`.
    /// Exceptions: `PulseError.notFound` for an unknown meal; `.server(status: 422)`
    /// on invalid item payload; other `PulseError` on failure.
    func addMealItem(mealId: UUID, item: NewMealItem) async throws -> MealItem {
        let url = try http.makeURL(path: "/meals/\(mealId.uuidString.lowercased())/items", query: [])
        let body = try JSONEncoder.pulseDefault().encode(item)
        return try await sendJSON(url: url, method: "POST", body: body)
    }

    /// Updates a meal item's mutable fields (`PATCH /meals/{id}/items/{item_id}`).
    /// The food source is not changed; only name/quantity/macros are sent.
    /// Inputs:
    ///   - mealId: the owning meal's id.
    ///   - itemId: the item's id.
    ///   - item: the rebuilt item carrying the new quantity + macros.
    /// Outputs: the updated `MealItem`.
    /// Exceptions: `PulseError.notFound` for an unknown meal/item; other `PulseError` on failure.
    func updateMealItem(mealId: UUID, itemId: UUID, item: NewMealItem) async throws -> MealItem {
        let url = try http.makeURL(
            path: "/meals/\(mealId.uuidString.lowercased())/items/\(itemId.uuidString.lowercased())",
            query: [])
        let body = try JSONEncoder.pulseDefault().encode(UpdateMealItemRequest(item: item))
        return try await sendJSON(url: url, method: "PATCH", body: body)
    }

    /// Removes an item from a saved meal (`DELETE /meals/{id}/items/{item_id}`).
    /// Inputs:
    ///   - mealId: the owning meal's id.
    ///   - itemId: the item's id.
    /// Outputs: nothing (204 on success).
    /// Exceptions: `PulseError.notFound` for an unknown meal/item; other `PulseError` on failure.
    func deleteMealItem(mealId: UUID, itemId: UUID) async throws {
        let url = try http.makeURL(
            path: "/meals/\(mealId.uuidString.lowercased())/items/\(itemId.uuidString.lowercased())",
            query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        http.applyAuth(&req)
        try await sendNoBody(request: req)
    }
}
