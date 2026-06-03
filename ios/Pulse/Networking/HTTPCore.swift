/// Shared HTTP transport core for the app's networking actors.
/// `HTTPCore` bundles the base URL, bearer session token, and `URLSession`, and
/// exposes the small set of transport primitives (`makeURL`, `applyAuth`, `raw`,
/// `mapStatus`, `multipartBody`) that `PulseClient` and `ProgressPhotoClient`
/// would otherwise each reimplement. It owns no decoding/encoding policy — each
/// client keeps its own `JSONDecoder`/`JSONEncoder` — only request shaping,
/// status mapping, and multipart encoding live here.
/// Role: single source of truth for HTTP behaviour, headers, and error mapping.
import Foundation

/// Value-type transport helper shared by the networking actors. Holds the
/// connection identity (base URL + bearer token) and the `URLSession`, and
/// performs request building, auth attachment, raw execution, status-to-error
/// mapping, and multipart body encoding. `Sendable` so it can be stored inside
/// an actor and read from its `nonisolated` members.
struct HTTPCore: Sendable {
    let baseURL: URL
    let sessionToken: String
    let session: URLSession

    /// Builds the core bound to a backend URL and bearer token.
    /// Inputs:
    ///   - baseURL: backend root URL (no trailing path).
    ///   - sessionToken: bearer token issued after sign-in.
    ///   - session: `URLSession` to use for all requests.
    /// Outputs: a configured `HTTPCore`.
    init(baseURL: URL, sessionToken: String, session: URLSession) {
        self.baseURL = baseURL
        self.sessionToken = sessionToken
        self.session = session
    }

    /// Composes a URL from the base, a path, and optional query items.
    /// Inputs:
    ///   - path: server path, leading slash included.
    ///   - query: query items; empty array produces a URL without `?`.
    /// Outputs: the resolved `URL`.
    /// Exceptions: `PulseError.notSignedIn` when URL composition fails.
    func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard var comps = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw PulseError.notSignedIn
        }
        comps.queryItems = query.isEmpty ? nil : query
        guard let url = comps.url else { throw PulseError.notSignedIn }
        return url
    }

    /// Attaches the bearer session token to a request's `Authorization` header.
    /// Inputs:
    ///   - req: request to mutate in place.
    /// Outputs: nothing.
    func applyAuth(_ req: inout URLRequest) {
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
    }

    /// Executes a request and returns the raw data plus `HTTPURLResponse`.
    /// Inputs:
    ///   - request: prepared `URLRequest`.
    /// Outputs: tuple of response body bytes and the `HTTPURLResponse`.
    /// Exceptions: `PulseError.network` wrapping a `URLError` for transport
    /// failures, or `PulseError.server(status: -1)` when the response is
    /// reachable but not HTTP (distinct from a transport error so ops can grep
    /// for the malformed-response path).
    func raw(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
    /// Outputs: nothing on a 2xx status.
    /// Exceptions: `.unauthorized` (401/403), `.notFound` (404),
    /// `.payloadTooLarge` (413), or `.server(status:)` for any other non-2xx
    /// (e.g. a 409 conflict surfaces as `.server(status: 409)`).
    func mapStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw PulseError.unauthorized
        case 404:      throw PulseError.notFound
        case 413:      throw PulseError.payloadTooLarge
        default:       throw PulseError.server(status: status)
        }
    }

    /// Builds a `multipart/form-data` body from zero or more text fields and a
    /// single file part, in that order.
    /// Inputs:
    ///   - boundary: multipart boundary string (without leading dashes).
    ///   - fields: ordered text fields, each emitted before the file part.
    ///   - file: the single file part (form field name, advertised filename,
    ///     MIME type, and payload bytes).
    /// Outputs: encoded multipart body data.
    static func multipartBody(
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
