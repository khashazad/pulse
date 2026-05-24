/// OAuth callback URL parsing for the Pulse sign-in flow.
/// Extracts the short-lived one-time exchange `code` (or an error reason) from
/// the deep-link URL the server redirects to after Google sign-in. The bearer
/// token is no longer carried in this URL — the app redeems the `code` over TLS
/// with its PKCE verifier. Used by the auth layer to convert a raw callback URL
/// into a typed `Result`.
import Foundation

/// Namespace for parsing the post-sign-in callback URL emitted by the server.
enum AuthCallbackParser {
    /// Parses the callback URL's query items into either the one-time exchange
    /// code or a `PulseError.signInFailed` with a reason string.
    /// Inputs:
    ///   - url: the deep-link URL delivered to the app after server redirect.
    /// Outputs: `.success(code)` when a non-empty `code` is present; otherwise
    /// `.failure(.signInFailed(reason:))` carrying the server-provided `error`
    /// value or `"invalid_callback"`.
    static func parse(_ url: URL) -> Result<String, PulseError> {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []

        if let error = items.first(where: { $0.name == "error" })?.value, !error.isEmpty {
            return .failure(.signInFailed(reason: error))
        }

        guard
            let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else {
            return .failure(.signInFailed(reason: "invalid_callback"))
        }
        return .success(code)
    }
}
