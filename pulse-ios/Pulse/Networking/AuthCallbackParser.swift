/// OAuth callback URL parsing for the diet-tracker sign-in flow.
/// Extracts session credentials (token + email) or an error reason from the
/// deep-link URL the server redirects to after Google sign-in. Used by the
/// auth layer to convert a raw callback URL into a typed `Result`.
import Foundation

/// Namespace for parsing the post-sign-in callback URL emitted by the server.
enum AuthCallbackParser {
    /// Successfully parsed credentials returned via callback query items.
    struct Credentials: Equatable {
        let token: String
        let email: String
    }

    /// Parses the callback URL's query items into either credentials or a
    /// `PulseError.signInFailed` with a reason string.
    /// Inputs:
    ///   - url: the deep-link URL delivered to the app after server redirect.
    /// Outputs: `.success(Credentials)` when token and email are both present
    /// and non-empty; otherwise `.failure(.signInFailed(reason:))` carrying
    /// the server-provided `error` value or `"invalid_callback"`.
    static func parse(_ url: URL) -> Result<Credentials, PulseError> {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []

        if let error = items.first(where: { $0.name == "error" })?.value, !error.isEmpty {
            return .failure(.signInFailed(reason: error))
        }

        guard
            let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty,
            let email = items.first(where: { $0.name == "email" })?.value, !email.isEmpty
        else {
            return .failure(.signInFailed(reason: "invalid_callback"))
        }
        return .success(Credentials(token: token, email: email))
    }
}
