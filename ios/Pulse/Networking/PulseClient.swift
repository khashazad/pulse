/// HTTP client for the diet-tracker FastAPI backend.
/// `PulseClient` is an actor that owns the session token, base URL, and
/// `URLSession`, exposing typed async methods for summary, logs, meals,
/// containers (incl. photo upload/delete), weight, calories, targets, and
/// auth endpoints. Internal helpers build URLs, attach bearer auth, encode
/// JSON/multipart bodies, and map HTTP status codes to `PulseError`.
/// This is the primary networking surface used by the app's view models.
import Foundation

/// Thread-safe HTTP client for the diet-tracker backend. All requests carry
/// a bearer session token; responses decode through `JSONDecoder.pulseDefault`.
actor PulseClient {
    private let baseURL: URL
    private let sessionToken: String
    private let session: URLSession
    private let decoder: JSONDecoder

    /// Builds a client bound to a backend URL and session token.
    /// Inputs:
    ///   - baseURL: backend root URL (no trailing path).
    ///   - sessionToken: bearer token issued after Google sign-in.
    ///   - session: `URLSession` to use (defaults to `.shared`).
    init(baseURL: URL, sessionToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.sessionToken = sessionToken
        self.session = session
        self.decoder = JSONDecoder.pulseDefault()
    }

    // MARK: - read endpoints

    /// Fetches the daily summary (totals + entries) for one date.
    /// Inputs:
    ///   - date: the calendar date to summarize.
    /// Outputs: `DailySummary` payload from `/summary/{date}`.
    /// Exceptions: `PulseError` for transport, auth, or decoding failures.
    func summary(date: Date) async throws -> DailySummary {
        let url = try makeURL(path: "/summary/\(DateOnly.string(from: date))", query: [])
        return try await fetch(url: url)
    }

    /// Lists raw food log entries between two dates inclusive.
    /// Inputs:
    ///   - from: start date.
    ///   - to: end date.
    /// Outputs: `LogsList` envelope from `/logs`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func logs(from: Date, to: Date) async throws -> LogsList {
        let url = try makeURL(
            path: "/logs",
            query: [
                URLQueryItem(name: "from", value: DateOnly.string(from: from)),
                URLQueryItem(name: "to", value: DateOnly.string(from: to)),
            ]
        )
        return try await fetch(url: url)
    }

    /// Lists all saved meals for the current user.
    /// Outputs: the array unwrapped from the `MealsListResponse` envelope.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func meals() async throws -> [MealSummary] {
        let url = try makeURL(path: "/meals", query: [])
        let envelope: MealsListResponse = try await fetch(url: url)
        return envelope.meals
    }

    /// Fetches a single meal with its items.
    /// Inputs:
    ///   - id: meal UUID.
    /// Outputs: the full `Meal`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func meal(id: UUID) async throws -> Meal {
        let url = try makeURL(path: "/meals/\(id.uuidString.lowercased())", query: [])
        return try await fetch(url: url)
    }

    // MARK: - entry / meal logging (writes)

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
        let url = try makeURL(path: "/entries", query: [])
        let body = try JSONEncoder.pulseDefault().encode(EntriesCreateRequest(items: items))
        return try await sendJSON(url: url, method: "POST", body: body)
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
        let url = try makeURL(path: "/meals/\(id.uuidString.lowercased())/log", query: [])
        let body = try JSONEncoder.pulseDefault().encode(LogMealRequest(consumedAt: consumedAt))
        return try await sendJSON(url: url, method: "POST", body: body)
    }

    // MARK: - containers

    /// Lists all containers for the current user.
    /// Outputs: the array unwrapped from the `ContainersList` envelope.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func listContainers() async throws -> [Container] {
        let url = try makeURL(path: "/containers", query: [])
        let list: ContainersList = try await fetch(url: url)
        return list.containers
    }

    /// Fetches a single container by id.
    /// Inputs:
    ///   - id: container UUID.
    /// Outputs: the `Container`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func getContainer(id: UUID) async throws -> Container {
        let url = try makeURL(path: "/containers/\(id.uuidString.lowercased())", query: [])
        return try await fetch(url: url)
    }

    /// Creates a container with a name and tare weight.
    /// Inputs:
    ///   - name: container display name.
    ///   - tareWeightG: empty-container weight in grams.
    /// Outputs: the newly created `Container`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func createContainer(name: String, tareWeightG: Double) async throws -> Container {
        let url = try makeURL(path: "/containers", query: [])
        let body: [String: Any] = ["name": name, "tare_weight_g": tareWeightG]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        return try await sendJSON(url: url, method: "POST", body: data)
    }

    /// Patches a container with any non-nil fields supplied.
    /// Inputs:
    ///   - id: container UUID.
    ///   - name: new name, or `nil` to leave unchanged.
    ///   - tareWeightG: new tare weight in grams, or `nil` to leave unchanged.
    /// Outputs: the updated `Container`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func updateContainer(id: UUID, name: String?, tareWeightG: Double?) async throws -> Container {
        var fields: [String: Any] = [:]
        if let name { fields["name"] = name }
        if let tareWeightG { fields["tare_weight_g"] = tareWeightG }
        let url = try makeURL(path: "/containers/\(id.uuidString.lowercased())", query: [])
        let data = try JSONSerialization.data(withJSONObject: fields, options: [])
        return try await sendJSON(url: url, method: "PATCH", body: data)
    }

    /// Deletes a container.
    /// Inputs:
    ///   - id: container UUID.
    /// Exceptions: `PulseError` on transport or auth failure.
    func deleteContainer(id: UUID) async throws {
        let url = try makeURL(path: "/containers/\(id.uuidString.lowercased())", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuth(&req)
        try await sendNoBody(request: req)
    }

    /// Uploads a JPEG photo for a container as multipart/form-data.
    /// Inputs:
    ///   - id: container UUID.
    ///   - jpegData: encoded JPEG bytes.
    /// Exceptions: `PulseError` on transport, auth, or `.payloadTooLarge`.
    func uploadContainerPhoto(id: UUID, jpegData: Data) async throws {
        let url = try makeURL(path: "/containers/\(id.uuidString.lowercased())/photo", query: [])
        let boundary = "----PulseBoundary\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        applyAuth(&req)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(
            boundary: boundary,
            fieldName: "file",
            filename: "photo.jpg",
            mimeType: "image/jpeg",
            data: jpegData
        )
        try await sendNoBody(request: req)
    }

    /// Deletes a container's photo.
    /// Inputs:
    ///   - id: container UUID.
    /// Exceptions: `PulseError` on transport or auth failure.
    func deleteContainerPhoto(id: UUID) async throws {
        let url = try makeURL(path: "/containers/\(id.uuidString.lowercased())/photo", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuth(&req)
        try await sendNoBody(request: req)
    }

    /// Builds an authenticated `URLRequest` that fetches a container's photo
    /// at the requested size. Marked `nonisolated` so SwiftUI image loaders
    /// can call it synchronously off the actor.
    /// Inputs:
    ///   - id: container UUID.
    ///   - size: requested image size variant.
    /// Outputs: the prepared `URLRequest` with bearer auth attached.
    nonisolated func containerPhotoRequest(id: UUID, size: ContainerPhotoSize) -> URLRequest {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("/containers/\(id.uuidString.lowercased())/photo"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "size", value: size.rawValue)]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: - food search

    /// Searches USDA FoodData Central via the server proxy.
    /// Inputs:
    ///   - query: search phrase (sent as `q`).
    ///   - limit: max results, 1...25.
    /// Outputs: normalized USDA hits (macros per-100g).
    /// Exceptions: `PulseError` on transport/auth/decoding; `.server(status: 429)` when rate-limited.
    func searchUSDA(query: String, limit: Int) async throws -> [USDAFoodResult] {
        let url = try makeURL(path: "/usda/search", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        let resp: USDASearchResponse = try await fetch(url: url)
        return resp.results
    }

    /// Lists the user's custom foods.
    /// Outputs: the array unwrapped from the `CustomFoodList` envelope.
    /// Exceptions: `PulseError` on transport/auth/decoding failure.
    func listCustomFoods() async throws -> [CustomFood] {
        let url = try makeURL(path: "/custom-foods", query: [])
        let list: CustomFoodList = try await fetch(url: url)
        return list.customFoods
    }

    /// Lists the user's food-memory entries.
    /// Outputs: the array unwrapped from the `FoodMemoryList` envelope.
    /// Exceptions: `PulseError` on transport/auth/decoding failure.
    func listFoodMemory() async throws -> [FoodMemoryEntry] {
        let url = try makeURL(path: "/food-memory", query: [])
        let list: FoodMemoryList = try await fetch(url: url)
        return list.entries
    }

    // MARK: - weight

    /// Lists weight entries between two dates inclusive.
    /// Inputs:
    ///   - from: start date.
    ///   - to: end date.
    /// Outputs: array of `WeightEntry`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func listWeightEntries(from: Date, to: Date) async throws -> [WeightEntry] {
        let url = try makeURL(
            path: "/weight",
            query: [
                URLQueryItem(name: "from", value: DateOnly.string(from: from)),
                URLQueryItem(name: "to", value: DateOnly.string(from: to)),
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
        let url = try makeURL(path: "/weight/\(DateOnly.string(from: date))", query: [])
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
        let url = try makeURL(path: "/weight/\(DateOnly.string(from: date))", query: [])
        let body: [String: Any] = ["weight": weight, "unit": unit.rawValue]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        return try await sendJSON(url: url, method: "PUT", body: data)
    }

    /// Deletes the weight entry for a date.
    /// Inputs:
    ///   - date: calendar date.
    /// Exceptions: `PulseError` on transport or auth failure.
    func deleteWeight(date: Date) async throws {
        let url = try makeURL(path: "/weight/\(DateOnly.string(from: date))", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuth(&req)
        try await sendNoBody(request: req)
    }

    /// Fetches the calories-per-day rollup view between two dates inclusive.
    /// Inputs:
    ///   - from: start date.
    ///   - to: end date.
    /// Outputs: array of `CaloriesDailyRow`, one per day with data.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func fetchCaloriesDaily(from: Date, to: Date) async throws -> [CaloriesDailyRow] {
        let url = try makeURL(
            path: "/calories_daily",
            query: [
                URLQueryItem(name: "from", value: DateOnly.string(from: from)),
                URLQueryItem(name: "to", value: DateOnly.string(from: to)),
            ]
        )
        return try await fetch(url: url)
    }

    /// Fetches the current macro/calorie targets.
    /// Outputs: the active `MacroTargets`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func fetchTargets() async throws -> MacroTargets {
        let url = try makeURL(path: "/targets", query: [])
        return try await fetch(url: url)
    }

    /// Creates or replaces the macro/calorie targets.
    /// Inputs:
    ///   - targets: new target values.
    /// Outputs: the persisted `MacroTargets`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func upsertTargets(_ targets: MacroTargets) async throws -> MacroTargets {
        let url = try makeURL(path: "/targets", query: [])
        let body = try JSONEncoder().encode(targets)
        return try await sendJSON(url: url, method: "PUT", body: body)
    }

    // MARK: - auth endpoints

    /// Calls `/auth/whoami` to confirm the bearer token and return identity.
    /// Outputs: the `WhoAmI` payload describing the current user.
    /// Exceptions: `PulseError.unauthorized` when the token is invalid;
    /// other `PulseError` cases on transport or decoding failure.
    func whoami() async throws -> WhoAmI {
        let url = try makeURL(path: "/auth/whoami", query: [])
        return try await fetch(url: url)
    }

    /// Invalidates the current server-side session.
    /// Exceptions: `PulseError` on transport or auth failure.
    func logout() async throws {
        let url = try makeURL(path: "/auth/logout", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAuth(&req)
        try await sendNoBody(request: req)
    }

    // MARK: - private helpers

    /// Composes a URL from the base, a path, and optional query items.
    /// Inputs:
    ///   - path: server path, leading slash included.
    ///   - query: query items; empty array produces a URL without `?`.
    /// Outputs: the resolved `URL`.
    /// Exceptions: `PulseError.notSignedIn` when URL composition fails.
    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw PulseError.notSignedIn
        }
        comps.queryItems = query.isEmpty ? nil : query
        guard let url = comps.url else { throw PulseError.notSignedIn }
        return url
    }

    /// Attaches the bearer session token to a request's `Authorization` header.
    /// Inputs:
    ///   - req: request to mutate in place.
    private func applyAuth(_ req: inout URLRequest) {
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
    }

    /// Performs a GET-style fetch and decodes JSON into `T`.
    /// Inputs:
    ///   - url: fully resolved request URL.
    /// Outputs: decoded value of type `T`.
    /// Exceptions: `PulseError` on transport, status, or decoding failure.
    private func fetch<T: Decodable>(url: URL) async throws -> T {
        var req = URLRequest(url: url)
        applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await sendDecoded(request: req)
    }

    /// Sends a JSON body with the given method and decodes the response.
    /// Inputs:
    ///   - url: request URL.
    ///   - method: HTTP method (`POST`, `PUT`, `PATCH`).
    ///   - body: encoded JSON request body.
    /// Outputs: decoded value of type `T`.
    /// Exceptions: `PulseError` on transport, status, or decoding failure.
    private func sendJSON<T: Decodable>(url: URL, method: String, body: Data) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = method
        applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body
        return try await sendDecoded(request: req)
    }

    /// Sends a fully prepared request and decodes the response body.
    /// Inputs:
    ///   - request: prepared `URLRequest`.
    /// Outputs: decoded value of type `T`.
    /// Exceptions: `PulseError.server`, `.unauthorized`, `.notFound`,
    /// `.payloadTooLarge`, `.network`, or `.decoding` per failure mode.
    private func sendDecoded<T: Decodable>(request: URLRequest) async throws -> T {
        let (data, http) = try await raw(request: request)
        try mapStatus(http.statusCode)
        do {
            return try decoder.decode(T.self, from: data)
        } catch let decodingError {
            throw PulseError.decoding(String(describing: decodingError))
        }
    }

    /// Sends a request expecting no decoded response body, only a status check.
    /// Inputs:
    ///   - request: prepared `URLRequest`.
    /// Exceptions: `PulseError` on non-2xx status or transport failure.
    private func sendNoBody(request: URLRequest) async throws {
        let (_, http) = try await raw(request: request)
        try mapStatus(http.statusCode)
    }

    /// Executes a request and returns the raw data plus `HTTPURLResponse`.
    /// Inputs:
    ///   - request: prepared `URLRequest`.
    /// Outputs: tuple of response body bytes and the `HTTPURLResponse`.
    /// Exceptions: `PulseError.network` wrapping a `URLError` for
    /// transport failures, or `PulseError.server(status: -1)` when the
    /// response is reachable but not HTTP (distinct from a transport error so
    /// ops can grep for the malformed-response path).
    private func raw(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw PulseError.network(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PulseError.server(status: -1)
        }
        return (data, http)
    }

    /// Maps an HTTP status code to a `PulseError` or returns on 2xx.
    /// Inputs:
    ///   - status: HTTP status code.
    /// Exceptions: `.unauthorized` (401/403), `.notFound` (404),
    /// `.payloadTooLarge` (413), or `.server(status:)` for any other non-2xx.
    private func mapStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw PulseError.unauthorized
        case 404:      throw PulseError.notFound
        case 413:      throw PulseError.payloadTooLarge
        default:       throw PulseError.server(status: status)
        }
    }

    /// Builds a single-part `multipart/form-data` body.
    /// Inputs:
    ///   - boundary: multipart boundary string (without leading dashes).
    ///   - fieldName: form field name.
    ///   - filename: filename to advertise in `Content-Disposition`.
    ///   - mimeType: MIME type of the part.
    ///   - data: payload bytes.
    /// Outputs: encoded multipart body data.
    private static func multipartBody(
        boundary: String,
        fieldName: String,
        filename: String,
        mimeType: String,
        data: Data
    ) -> Data {
        var body = Data()
        let lineBreak = "\r\n"
        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(data)
        body.append("\(lineBreak)--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        return body
    }
}
