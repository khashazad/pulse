/// HTTP client for the progress-photos feature (`/measures/photos`).
/// `ProgressPhotoClient` is an actor that lists metadata, downloads slot
/// images at full or thumb size, and uploads single or batched JPEGs as
/// multipart bodies. Mirrors the auth + error-mapping conventions of
/// `DietTrackerClient`. Used by the Progress Photos view and capture flow.
import Foundation

/// Thread-safe HTTP client scoped to the progress-photos endpoints.
actor ProgressPhotoClient {
    /// Image size variant requested from the server.
    enum Size: String { case full, thumb }

    private let baseURL: URL
    private let sessionToken: String
    private let session: URLSession
    private let decoder: JSONDecoder

    /// Builds a client bound to the backend URL and session token.
    /// Inputs:
    ///   - baseURL: backend root URL.
    ///   - sessionToken: bearer token issued after Google sign-in.
    ///   - session: `URLSession` to use (defaults to `.shared`).
    init(baseURL: URL, sessionToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.sessionToken = sessionToken
        self.session = session
        self.decoder = JSONDecoder.dietTrackerDefault()
    }

    /// Lists progress photo metadata for a date range inclusive.
    /// Inputs:
    ///   - frm: start date.
    ///   - to: end date.
    /// Outputs: array of `ProgressPhotoMetadata`, one per (date, slot).
    /// Exceptions: `DietTrackerError` on transport, status, or decoding failure.
    func listMetadata(from frm: Date, to: Date) async throws -> [ProgressPhotoMetadata] {
        let url = try makeURL(
            path: "/measures/photos",
            query: [
                URLQueryItem(name: "from", value: DateOnly.string(from: frm)),
                URLQueryItem(name: "to", value: DateOnly.string(from: to)),
            ]
        )
        var req = URLRequest(url: url)
        applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await raw(request: req)
        try mapStatus(http.statusCode)
        do {
            return try decoder.decode([ProgressPhotoMetadata].self, from: data)
        } catch {
            throw DietTrackerError.decoding(String(describing: error))
        }
    }

    /// Downloads the raw JPEG bytes for a slot/date at the requested size.
    /// Inputs:
    ///   - date: calendar date.
    ///   - slot: photo slot (front/side/back).
    ///   - size: `.full` or `.thumb`.
    /// Outputs: the JPEG payload bytes.
    /// Exceptions: `DietTrackerError` on transport, status, or auth failure.
    func download(date: Date, slot: ProgressPhotoSlot, size: Size) async throws -> Data {
        let url = try makeURL(
            path: "/measures/photos/\(DateOnly.string(from: date))/\(slot.rawValue)",
            query: [URLQueryItem(name: "size", value: size.rawValue)]
        )
        var req = URLRequest(url: url)
        applyAuth(&req)
        let (data, http) = try await raw(request: req)
        try mapStatus(http.statusCode)
        return data
    }

    /// Uploads a single JPEG to a specific slot/date.
    /// Inputs:
    ///   - date: calendar date.
    ///   - slot: target photo slot.
    ///   - jpeg: encoded JPEG bytes.
    /// Outputs: persisted `ProgressPhotoMetadata` for the slot.
    /// Exceptions: `DietTrackerError` on transport, auth, `.payloadTooLarge`,
    /// or decoding failure.
    func upload(date: Date, slot: ProgressPhotoSlot, jpeg: Data) async throws -> ProgressPhotoMetadata {
        let url = try makeURL(
            path: "/measures/photos/\(DateOnly.string(from: date))/\(slot.rawValue)",
            query: []
        )
        let boundary = "----DietTrackerBoundary\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        applyAuth(&req)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(
            boundary: boundary,
            parts: [(fieldName: "file", filename: "photo.jpg", mime: "image/jpeg", data: jpeg)]
        )
        let (data, http) = try await raw(request: req)
        try mapStatus(http.statusCode)
        do {
            return try decoder.decode(ProgressPhotoMetadata.self, from: data)
        } catch {
            throw DietTrackerError.decoding(String(describing: error))
        }
    }

    /// Uploads multiple JPEGs to distinct slots on the same date in one request.
    /// Inputs:
    ///   - date: calendar date for all photos.
    ///   - assignments: map of slot -> JPEG bytes; each entry becomes one
    ///     multipart part whose field name is the slot raw value.
    /// Outputs: metadata for every persisted slot.
    /// Exceptions: `DietTrackerError` on transport, auth, `.payloadTooLarge`,
    /// or decoding failure.
    func uploadBatch(
        date: Date,
        assignments: [ProgressPhotoSlot: Data]
    ) async throws -> [ProgressPhotoMetadata] {
        let url = try makeURL(
            path: "/measures/photos/\(DateOnly.string(from: date))",
            query: []
        )
        let boundary = "----DietTrackerBoundary\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        applyAuth(&req)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let parts: [(fieldName: String, filename: String, mime: String, data: Data)] =
            assignments.map { slot, data in
                (fieldName: slot.rawValue, filename: "\(slot.rawValue).jpg", mime: "image/jpeg", data: data)
            }
        req.httpBody = Self.multipartBody(boundary: boundary, parts: parts)
        let (data, http) = try await raw(request: req)
        try mapStatus(http.statusCode)
        do {
            return try decoder.decode([ProgressPhotoMetadata].self, from: data)
        } catch {
            throw DietTrackerError.decoding(String(describing: error))
        }
    }

    /// Deletes the photo at a given slot/date.
    /// Inputs:
    ///   - date: calendar date.
    ///   - slot: photo slot to delete.
    /// Exceptions: `DietTrackerError` on transport, status, or auth failure.
    func delete(date: Date, slot: ProgressPhotoSlot) async throws {
        let url = try makeURL(
            path: "/measures/photos/\(DateOnly.string(from: date))/\(slot.rawValue)",
            query: []
        )
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuth(&req)
        let (_, http) = try await raw(request: req)
        try mapStatus(http.statusCode)
    }

    // MARK: helpers

    /// Composes a URL from the base, a path, and optional query items.
    /// Inputs:
    ///   - path: server path, leading slash included.
    ///   - query: query items; empty array produces a URL without `?`.
    /// Outputs: the resolved `URL`.
    /// Exceptions: `DietTrackerError.notSignedIn` when URL composition fails.
    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard var comps = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw DietTrackerError.notSignedIn }
        comps.queryItems = query.isEmpty ? nil : query
        guard let url = comps.url else { throw DietTrackerError.notSignedIn }
        return url
    }

    /// Attaches the bearer session token to a request's `Authorization` header.
    /// Inputs:
    ///   - req: request to mutate in place.
    private func applyAuth(_ req: inout URLRequest) {
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
    }

    /// Executes a request and returns the raw data plus `HTTPURLResponse`.
    /// Inputs:
    ///   - request: prepared `URLRequest`.
    /// Outputs: tuple of response body bytes and the `HTTPURLResponse`.
    /// Exceptions: `DietTrackerError.network` wrapping a `URLError`, or
    /// `DietTrackerError.server(status: -1)` if the response isn't HTTP.
    private func raw(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DietTrackerError.server(status: -1)
            }
            return (data, http)
        } catch let urlError as URLError {
            throw DietTrackerError.network(urlError)
        }
    }

    /// Maps an HTTP status code to a `DietTrackerError` or returns on 2xx.
    /// Inputs:
    ///   - status: HTTP status code.
    /// Exceptions: `.unauthorized` (401/403), `.notFound` (404),
    /// `.payloadTooLarge` (413), or `.server(status:)` for any other non-2xx.
    private func mapStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw DietTrackerError.unauthorized
        case 404:      throw DietTrackerError.notFound
        case 413:      throw DietTrackerError.payloadTooLarge
        default:       throw DietTrackerError.server(status: status)
        }
    }

    /// Builds a multi-part `multipart/form-data` body.
    /// Inputs:
    ///   - boundary: multipart boundary string (without leading dashes).
    ///   - parts: array of (field name, filename, MIME type, payload bytes)
    ///     describing each part to include.
    /// Outputs: encoded multipart body data with trailing closing boundary.
    private static func multipartBody(
        boundary: String,
        parts: [(fieldName: String, filename: String, mime: String, data: Data)]
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"
        for part in parts {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"\(part.fieldName)\"; filename=\"\(part.filename)\"\(crlf)"
                    .data(using: .utf8)!
            )
            body.append("Content-Type: \(part.mime)\(crlf)\(crlf)".data(using: .utf8)!)
            body.append(part.data)
            body.append(crlf.data(using: .utf8)!)
        }
        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        return body
    }
}
