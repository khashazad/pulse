/// HTTP client for the progress-photos feature (`/measures/photos`,
/// `/measures/photo-tags`).
/// `ProgressPhotoClient` is an actor that lists tag and photo metadata,
/// downloads photo bytes at full or thumb size, uploads a tagged photo as a
/// multipart body, deletes a photo by id, and creates / renames tags.
/// Shares the transport core (`HTTPCore`) with `PulseClient`; it keeps its own
/// ISO-8601 `JSONEncoder` for request bodies.
/// Used by the Progress Photos view, tag store, and capture flow.
import Foundation

/// Thread-safe HTTP client scoped to the progress-photos endpoints.
actor ProgressPhotoClient {
    private let http: HTTPCore
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// Builds a client bound to the backend URL and session token.
    /// Inputs:
    ///   - baseURL: backend root URL.
    ///   - sessionToken: bearer token issued after Google sign-in.
    ///   - session: `URLSession` to use (defaults to `.shared`).
    init(baseURL: URL, sessionToken: String, session: URLSession = .shared) {
        self.http = HTTPCore(baseURL: baseURL, sessionToken: sessionToken, session: session)
        self.decoder = JSONDecoder.pulseDefault()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    // MARK: photo metadata

    /// Lists progress-photo metadata for an inclusive date range.
    func listMetadata(from frm: Date, to: Date) async throws -> [ProgressPhotoMetadata] {
        let url = try http.makeURL(
            path: "/measures/photos",
            query: [
                URLQueryItem(name: "from", value: DateOnly.string(from: frm)),
                URLQueryItem(name: "to", value: DateOnly.string(from: to))
            ]
        )
        var req = URLRequest(url: url)
        http.applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.raw(request: req)
        try http.mapStatus(response.statusCode)
        do {
            return try decoder.decode([ProgressPhotoMetadata].self, from: data)
        } catch {
            throw PulseError.decoding(String(describing: error))
        }
    }

    /// Downloads raw JPEG bytes for a photo at the requested size.
    func download(photoId: UUID, size: PhotoSize) async throws -> Data {
        let url = try http.makeURL(
            path: "/measures/photos/\(photoId.uuidString.lowercased())",
            query: [URLQueryItem(name: "size", value: size.rawValue)]
        )
        var req = URLRequest(url: url)
        http.applyAuth(&req)
        let (data, response) = try await http.raw(request: req)
        try http.mapStatus(response.statusCode)
        return data
    }

    /// Uploads a JPEG tagged with `tagId` for `date` and returns the persisted metadata.
    /// `idempotencyKey` lets the server dedupe retries of the same logical upload:
    /// a second POST with the same key returns the previously-inserted row instead
    /// of creating a duplicate. Pass `nil` for one-shot uploads that won't be retried.
    func upload(
        date: Date,
        tagId: UUID,
        jpeg: Data,
        idempotencyKey: UUID? = nil
    ) async throws -> ProgressPhotoMetadata {
        let url = try http.makeURL(path: "/measures/photos", query: [])
        let boundary = "----PulseBoundary\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        http.applyAuth(&req)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var fields: [(name: String, value: String)] = [
            ("log_date", DateOnly.string(from: date)),
            ("tag_id", tagId.uuidString.lowercased())
        ]
        if let idempotencyKey {
            fields.append(("idempotency_key", idempotencyKey.uuidString.lowercased()))
        }
        req.httpBody = HTTPCore.multipartBody(
            boundary: boundary,
            fields: fields,
            file: (fieldName: "file", filename: "photo.jpg", mime: "image/jpeg", data: jpeg)
        )
        let (data, response) = try await http.raw(request: req)
        try http.mapStatus(response.statusCode)
        do {
            return try decoder.decode(ProgressPhotoMetadata.self, from: data)
        } catch {
            throw PulseError.decoding(String(describing: error))
        }
    }

    /// Deletes a photo by id.
    func delete(photoId: UUID) async throws {
        let url = try http.makeURL(
            path: "/measures/photos/\(photoId.uuidString.lowercased())",
            query: []
        )
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        http.applyAuth(&req)
        let (_, response) = try await http.raw(request: req)
        try http.mapStatus(response.statusCode)
    }

    // MARK: tags

    /// Lists the user's progress-photo tags (server auto-seeds defaults on first call).
    func listTags() async throws -> [ProgressPhotoTag] {
        let url = try http.makeURL(path: "/measures/photo-tags", query: [])
        var req = URLRequest(url: url)
        http.applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.raw(request: req)
        try http.mapStatus(response.statusCode)
        do {
            return try decoder.decode([ProgressPhotoTag].self, from: data)
        } catch {
            throw PulseError.decoding(String(describing: error))
        }
    }

    /// Creates a new tag with the supplied display name.
    func createTag(name: String) async throws -> ProgressPhotoTag {
        let url = try http.makeURL(path: "/measures/photo-tags", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        http.applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try encoder.encode(["name": name])
        let (data, response) = try await http.raw(request: req)
        try http.mapStatus(response.statusCode)
        do {
            return try decoder.decode(ProgressPhotoTag.self, from: data)
        } catch {
            throw PulseError.decoding(String(describing: error))
        }
    }

    /// Renames and/or reorders an existing tag. At least one of the fields must be non-nil.
    func updateTag(
        id: UUID,
        name: String? = nil,
        sortOrder: Int? = nil
    ) async throws -> ProgressPhotoTag {
        let url = try http.makeURL(
            path: "/measures/photo-tags/\(id.uuidString.lowercased())",
            query: []
        )
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        http.applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try encoder.encode(UpdateTagRequest(name: name, sortOrder: sortOrder))
        let (data, response) = try await http.raw(request: req)
        try http.mapStatus(response.statusCode)
        do {
            return try decoder.decode(ProgressPhotoTag.self, from: data)
        } catch {
            throw PulseError.decoding(String(describing: error))
        }
    }
}

/// Request body for `PATCH /measures/photo-tags/{id}`. Optional fields are
/// encoded only when present, so a nil value omits the key entirely rather than
/// sending `null` — matching the partial-update contract the server expects.
private struct UpdateTagRequest: Encodable {
    let name: String?
    let sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case sortOrder = "sort_order"
    }

    /// Encodes only the non-nil fields so omitted keys do not appear as `null`.
    /// Inputs:
    ///   - encoder: the encoder to write into.
    /// Outputs: nothing.
    /// Exceptions: rethrows any encoding error.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(sortOrder, forKey: .sortOrder)
    }
}
