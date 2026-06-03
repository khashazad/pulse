/// HTTP client for the diet-tracker FastAPI backend.
/// `PulseClient` is an actor that owns the session token, base URL, and
/// `URLSession` (bundled in a shared `HTTPCore`), exposing typed async methods
/// for summary, logs, meals, containers (incl. photo upload/delete), weight,
/// calories, targets, and auth endpoints. The per-domain methods live in
/// `PulseClient+*.swift` extensions; this file holds the actor's stored state,
/// init, and the send helpers that wrap `HTTPCore` with this client's
/// `JSONDecoder.pulseDefault` decoding.
/// This is the primary networking surface used by the app's view models.
import Foundation

/// Thread-safe HTTP client for the diet-tracker backend. All requests carry
/// a bearer session token; responses decode through `JSONDecoder.pulseDefault`.
actor PulseClient {
    /// Shared transport core: base URL, bearer token, session, and the
    /// request-building / status-mapping / multipart primitives.
    let http: HTTPCore
    private let decoder: JSONDecoder

    /// Builds a client bound to a backend URL and session token.
    /// Inputs:
    ///   - baseURL: backend root URL (no trailing path).
    ///   - sessionToken: bearer token issued after Google sign-in.
    ///   - session: `URLSession` to use (defaults to `.shared`).
    init(baseURL: URL, sessionToken: String, session: URLSession = .shared) {
        self.http = HTTPCore(baseURL: baseURL, sessionToken: sessionToken, session: session)
        self.decoder = JSONDecoder.pulseDefault()
    }

    // MARK: - send helpers

    /// Performs a GET-style fetch and decodes JSON into `T`.
    /// Inputs:
    ///   - url: fully resolved request URL.
    /// Outputs: decoded value of type `T`.
    /// Exceptions: `PulseError` on transport, status, or decoding failure.
    func fetch<T: Decodable>(url: URL) async throws -> T {
        var req = URLRequest(url: url)
        http.applyAuth(&req)
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
    func sendJSON<T: Decodable>(url: URL, method: String, body: Data) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = method
        http.applyAuth(&req)
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
    func sendDecoded<T: Decodable>(request: URLRequest) async throws -> T {
        let (data, response) = try await http.raw(request: request)
        try http.mapStatus(response.statusCode)
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
    func sendNoBody(request: URLRequest) async throws {
        let (_, response) = try await http.raw(request: request)
        try http.mapStatus(response.statusCode)
    }
}
