/// `PulseClient` targets + auth endpoints: fetch/upsert macro-calorie targets
/// and the `whoami` / `logout` session calls.
/// Pure code organization — signatures and behaviour (including the plain
/// `JSONEncoder()` used for the targets body) are unchanged.
import Foundation

extension PulseClient {
    // MARK: - targets

    /// Fetches the current macro/calorie targets.
    /// Outputs: the active `MacroTargets`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func fetchTargets() async throws -> MacroTargets {
        let url = try http.makeURL(path: "/targets", query: [])
        return try await fetch(url: url)
    }

    /// Creates or replaces the macro/calorie targets.
    /// Inputs:
    ///   - targets: new target values.
    /// Outputs: the persisted `MacroTargets`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func upsertTargets(_ targets: MacroTargets) async throws -> MacroTargets {
        let url = try http.makeURL(path: "/targets", query: [])
        let body = try JSONEncoder().encode(targets)
        return try await sendJSON(url: url, method: "PUT", body: body)
    }

    // MARK: - auth

    /// Calls `/auth/whoami` to confirm the bearer token and return identity.
    /// Outputs: the `WhoAmI` payload describing the current user.
    /// Exceptions: `PulseError.unauthorized` when the token is invalid;
    /// other `PulseError` cases on transport or decoding failure.
    func whoami() async throws -> WhoAmI {
        let url = try http.makeURL(path: "/auth/whoami", query: [])
        return try await fetch(url: url)
    }

    /// Invalidates the current server-side session.
    /// Exceptions: `PulseError` on transport or auth failure.
    func logout() async throws {
        let url = try http.makeURL(path: "/auth/logout", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        http.applyAuth(&req)
        try await sendNoBody(request: req)
    }
}
