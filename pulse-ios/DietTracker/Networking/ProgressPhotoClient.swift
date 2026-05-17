import Foundation

actor ProgressPhotoClient {
    enum Size: String { case full, thumb }

    private let baseURL: URL
    private let sessionToken: String
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL, sessionToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.sessionToken = sessionToken
        self.session = session
        self.decoder = JSONDecoder.dietTrackerDefault()
    }

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

    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard var comps = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw DietTrackerError.notSignedIn }
        comps.queryItems = query.isEmpty ? nil : query
        guard let url = comps.url else { throw DietTrackerError.notSignedIn }
        return url
    }

    private func applyAuth(_ req: inout URLRequest) {
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
    }

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

    private func mapStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw DietTrackerError.unauthorized
        case 404:      throw DietTrackerError.notFound
        case 413:      throw DietTrackerError.payloadTooLarge
        default:       throw DietTrackerError.server(status: status)
        }
    }

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
