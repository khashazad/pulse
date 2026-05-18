/// HTTP client for the progress-photos feature (`/measures/photos`,
/// `/measures/photo-tags`).
/// `ProgressPhotoClient` is an actor that lists tag and photo metadata,
/// downloads photo bytes at full or thumb size, uploads a tagged photo as a
/// multipart body, deletes a photo by id, and creates / renames tags.
/// Mirrors the auth + error-mapping conventions of `DietTrackerClient`.
/// Used by the Progress Photos view, tag store, and capture flow.
import Foundation

/// Thread-safe HTTP client scoped to the progress-photos endpoints.
actor ProgressPhotoClient {
    /// Image size variant requested from the server.
    enum Size: String { case full, thumb }

    private let baseURL: URL
    private let sessionToken: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

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
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    // MARK: photo metadata

    /// Lists progress-photo metadata for an inclusive date range.
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

    /// Downloads raw JPEG bytes for a photo at the requested size.
    func download(photoId: UUID, size: Size) async throws -> Data {
        let url = try makeURL(
            path: "/measures/photos/\(photoId.uuidString.lowercased())",
            query: [URLQueryItem(name: "size", value: size.rawValue)]
        )
        var req = URLRequest(url: url)
        applyAuth(&req)
        let (data, http) = try await raw(request: req)
        try mapStatus(http.statusCode)
        return data
    }

    /// Uploads a JPEG tagged with `tagId` for `date` and returns the persisted metadata.
    func upload(
        date: Date,
        tagId: UUID,
        jpeg: Data
    ) async throws -> ProgressPhotoMetadata {
        let url = try makeURL(path: "/measures/photos", query: [])
        let boundary = "----DietTrackerBoundary\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAuth(&req)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(
            boundary: boundary,
            fields: [
                ("log_date", DateOnly.string(from: date)),
                ("tag_id", tagId.uuidString.lowercased()),
            ],
            file: (fieldName: "file", filename: "photo.jpg", mime: "image/jpeg", data: jpeg)
        )
        let (data, http) = try await raw(request: req)
        try mapStatus(http.statusCode)
        do {
            return try decoder.decode(ProgressPhotoMetadata.self, from: data)
        } catch {
            throw DietTrackerError.decoding(String(describing: error))
        }
    }

    /// Deletes a photo by id.
    func delete(photoId: UUID) async throws {
        let url = try makeURL(
            path: "/measures/photos/\(photoId.uuidString.lowercased())",
            query: []
        )
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuth(&req)
        let (_, http) = try await raw(request: req)
        try mapStatus(http.statusCode)
    }

    // MARK: tags

    /// Lists the user's progress-photo tags (server auto-seeds defaults on first call).
    func listTags() async throws -> [ProgressPhotoTag] {
        let url = try makeURL(path: "/measures/photo-tags", query: [])
        var req = URLRequest(url: url)
        applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await raw(request: req)
        try mapStatus(http.statusCode)
        do {
            return try decoder.decode([ProgressPhotoTag].self, from: data)
        } catch {
            throw DietTrackerError.decoding(String(describing: error))
        }
    }

    /// Creates a new tag with the supplied display name.
    func createTag(name: String) async throws -> ProgressPhotoTag {
        let url = try makeURL(path: "/measures/photo-tags", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try encoder.encode(["name": name])
        let (data, http) = try await raw(request: req)
        try mapStatus(http.statusCode)
        do {
            return try decoder.decode(ProgressPhotoTag.self, from: data)
        } catch {
            throw DietTrackerError.decoding(String(describing: error))
        }
    }

    /// Renames and/or reorders an existing tag. At least one of the fields must be non-nil.
    func updateTag(
        id: UUID,
        name: String? = nil,
        sortOrder: Int? = nil
    ) async throws -> ProgressPhotoTag {
        let url = try makeURL(
            path: "/measures/photo-tags/\(id.uuidString.lowercased())",
            query: []
        )
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var payload: [String: Any] = [:]
        if let name { payload["name"] = name }
        if let sortOrder { payload["sort_order"] = sortOrder }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, http) = try await raw(request: req)
        try mapStatus(http.statusCode)
        do {
            return try decoder.decode(ProgressPhotoTag.self, from: data)
        } catch {
            throw DietTrackerError.decoding(String(describing: error))
        }
    }

    // MARK: helpers

    /// Composes a URL from the base, a path, and optional query items.
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
    private func applyAuth(_ req: inout URLRequest) {
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
    }

    /// Executes a request and returns the raw data plus `HTTPURLResponse`.
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
    private func mapStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw DietTrackerError.unauthorized
        case 404:      throw DietTrackerError.notFound
        case 409:      throw DietTrackerError.server(status: 409)
        case 413:      throw DietTrackerError.payloadTooLarge
        default:       throw DietTrackerError.server(status: status)
        }
    }

    /// Builds a multipart body containing text fields and a single file part.
    private static func multipartBody(
        boundary: String,
        fields: [(name: String, value: String)],
        file: (fieldName: String, filename: String, mime: String, data: Data)
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"
        for field in fields {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"\(field.name)\"\(crlf)\(crlf)"
                    .data(using: .utf8)!
            )
            body.append(field.value.data(using: .utf8)!)
            body.append(crlf.data(using: .utf8)!)
        }
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.filename)\"\(crlf)"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(file.mime)\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(file.data)
        body.append(crlf.data(using: .utf8)!)
        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        return body
    }
}
